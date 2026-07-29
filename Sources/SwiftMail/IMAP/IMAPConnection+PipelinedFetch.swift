import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

extension IMAPConnection {
    /// Result of a single pipelined fetch-part command.
    struct PipelinedFetchResult: Sendable {
        let uid: UID
        let section: Section
        let data: Data
    }

    /// Internal record of a tagged pipelined fetch request.
    struct TaggedFetchRequest {
        let tag: String
        let uid: UID
        let section: Section
    }

    /// Serial part fetches allow each command its own 60-second window; a pipelined
    /// batch shares one timeout. Scale it with the batch size (capped) so a large
    /// multipart message on a slow link does not time out where serial fetching
    /// succeeded.
    static func defaultPipelinedFetchTimeout(partCount: Int) -> Int {
        guard partCount > 1 else { return 60 }
        return min(60 + (partCount - 1) * 30, 300)
    }

    /// Execute multiple FETCH BODY[section] commands in a pipelined burst.
    /// Sends all commands without awaiting individual responses (RFC 3501 §5.5).
    /// The PipelinedCommandDispatcher routes responses to the correct handler by tag,
    /// content-verifying against each request's UID and section where the server's
    /// responses identify themselves. All commands execute under a single commandQueue
    /// lock — no interleaving.
    ///
    /// Individual command failures are tolerated: their (uid, section) pairs are simply
    /// absent from the results. When a failure indicates the connection itself is bad
    /// (timeout, channel drop), the connection is recycled before returning so the next
    /// command starts from a clean channel instead of reading another command's stale
    /// literals.
    ///
    /// - Parameter requests: Array of (uid, section) pairs to fetch.
    /// - Parameter timeoutSeconds: Optional timeout override for the entire batch.
    ///   Defaults to a value scaled with the request count.
    /// - Returns: Array of results with fetched data per (uid, section).
    /// - Throws: If the connection is unavailable, if a parser limit is violated, or
    ///   if every command in the batch fails (the first failure is rethrown).
    func executePipelinedFetchParts(
        requests: [(uid: UID, section: Section)],
        timeoutSeconds: Int? = nil
    ) async throws -> [PipelinedFetchResult] {
        guard !requests.isEmpty else { return [] }
        let timeout = timeoutSeconds
            ?? Self.defaultPipelinedFetchTimeout(partCount: requests.count)

        return try await commandQueue.run { [self] in
            try await self.pipelinedFetchPartsBody(requests: requests, timeoutSeconds: timeout)
        }
    }

    private func pipelinedFetchPartsBody(
        requests: [(uid: UID, section: Section)],
        timeoutSeconds: Int
    ) async throws -> [PipelinedFetchResult] {
        // A caller cancelled while queued for the command lock must not dispatch
        // its burst: once on the wire the batch is not cancellation-responsive,
        // so this check is the last point where a superseded fetch can bow out
        // without holding the connection for the full batch.
        try Task.checkCancellation()
        let channel = try await preparePipelinedFetchChannel()

        // Create promises and handlers for each request.
        // Handlers are kept in an array so timeout/error can fail them safely
        // through their double-resolve guards (never call promise.fail directly).
        let dispatcher = PipelinedCommandDispatcher()
        let registered = registerPipelinedFetchRequests(
            requests: requests,
            channel: channel,
            dispatcher: dispatcher
        )

        try await channel.pipeline.addHandler(dispatcher, position: .before(responseBuffer)).get()
        responseBuffer.hasActiveHandler = true

        let scheduledTimeout = schedulePipelinedFetchTimeout(
            channel: channel,
            timeoutSeconds: timeoutSeconds,
            handlers: registered.handlers
        )

        do {
            try await dispatchPipelinedFetchCommands(
                tagToRequest: registered.tagToRequest,
                handlers: registered.handlers,
                channel: channel,
                dispatcher: dispatcher,
                scheduledTimeout: scheduledTimeout
            )
        } catch {
            // Mirror the serial path: a failed send usually means a dead channel.
            if shouldRecycleConnection(for: error) {
                try? await disconnectBody()
            }
            throw error
        }

        // Runs on both paths, because a limit violation now throws out of the collection step —
        // otherwise a hostile server could leave the dispatcher installed and `hasActiveHandler`
        // set, which would wedge the next command. Ordering matters: the response buffer has to
        // resume buffering *before* the dispatcher is removed, or an unsolicited response
        // (BYE, EXISTS) arriving during the removal await is neither dispatched nor buffered.
        func restoreChannelState() {
            scheduledTimeout.cancel()
            responseBuffer.hasActiveHandler = false
            duplexLogger.flushInboundBuffer()
        }

        let drain = await drainPipelinedFetchFutures(
            tagToRequest: registered.tagToRequest,
            futures: registered.futures
        )
        restoreChannelState()
        // Remove dispatcher — may already be removed if channelInactive fired
        try? await channel.pipeline.removeHandler(dispatcher)

        return try await resolvePipelinedFetchDrain(drain)
    }

    /// Applies the failure policy to a drained batch: limit violations always throw
    /// (the channel was already closed by ``IMAPResponseLimitGuard``); ordinary
    /// failures recycle the connection when they indicate a bad channel and throw
    /// only when nothing succeeded.
    private func resolvePipelinedFetchDrain(
        _ drain: PipelinedFetchDrain
    ) async throws -> [PipelinedFetchResult] {
        if let limitViolation = drain.firstLimitViolation {
            throw limitViolation
        }
        if let routingViolation = drain.firstRoutingViolation {
            let message = "\(connectionContext) Recycling connection after pipelined routing violation: "
                + "\(routingViolation)"
            logger.warning("\(message)")
            try? await disconnectBody()
            throw routingViolation
        }
        // A timeout or channel drop poisons the connection even when some parts
        // arrived intact: literals for the failed tags may still be streaming,
        // and the next command would read them as its own response. Recycle on
        // ANY recyclable failure in the batch (not just the first-by-send-order
        // failure) before anyone reuses the channel; successful results stay valid.
        if let recyclableFailure = drain.firstRecyclableFailure {
            let message = "\(connectionContext) Recycling connection after pipelined fetch failure: "
                + "\(recyclableFailure)"
            logger.warning("\(message)")
            try? await disconnectBody()
        }
        if let failure = drain.firstFailure, drain.results.isEmpty {
            throw failure
        }
        return drain.results
    }

    private func preparePipelinedFetchChannel() async throws -> Channel {
        try await waitForIdleCompletionIfNeeded()
        try await recycleConnectionIfBufferedTerminationIfNeeded(operation: "PipelinedFetchParts")

        clearInvalidChannel()
        if self.channel == nil {
            logger.info("\(connectionContext) Channel is nil, re-establishing connection before pipelined fetch")
            try await connectBody()
        }

        guard let channel = self.channel, channel.isActive else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }
        return channel
    }

    struct RegisteredPipelinedFetch {
        let tagToRequest: [TaggedFetchRequest]
        let handlers: [PipelinedFetchPartHandler]
        let futures: [EventLoopFuture<Data>]
    }

    private func registerPipelinedFetchRequests(
        requests: [(uid: UID, section: Section)],
        channel: Channel,
        dispatcher: PipelinedCommandDispatcher
    ) -> RegisteredPipelinedFetch {
        var tagToRequest: [TaggedFetchRequest] = []
        var handlers: [PipelinedFetchPartHandler] = []
        var futures: [EventLoopFuture<Data>] = []

        for request in requests {
            let tag = generateCommandTag()
            let promise = channel.eventLoop.makePromise(of: Data.self)
            let handler = PipelinedFetchPartHandler(promise: promise)
            // Register the expected UID and section (mirroring the encoding in
            // FetchMessagePartCommand.toTaggedCommand) so the dispatcher can
            // content-verify untagged responses instead of trusting send order.
            dispatcher.register(
                tag: tag,
                handler: handler,
                uid: request.uid,
                expectedSection: SectionSpecifier(part: SectionSpecifier.Part(request.section.components))
            )
            tagToRequest.append(TaggedFetchRequest(tag: tag, uid: request.uid, section: request.section))
            handlers.append(handler)
            futures.append(promise.futureResult)
        }

        return RegisteredPipelinedFetch(tagToRequest: tagToRequest, handlers: handlers, futures: futures)
    }

    private func schedulePipelinedFetchTimeout(
        channel: Channel,
        timeoutSeconds: Int,
        handlers: [PipelinedFetchPartHandler]
    ) -> Scheduled<Void> {
        // Timeout for the entire batch — fails through handlers (not raw promises)
        // to respect PipelinedFetchPartHandler's double-resolve guard.
        let capturedHandlers = handlers
        let logger = self.logger
        return channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            logger.warning("Pipelined fetch timed out after \(timeoutSeconds) seconds")
            let error = IMAPError.timeout
            for handler in capturedHandlers {
                handler.fail(error)
            }
        }
    }

    private func dispatchPipelinedFetchCommands(
        tagToRequest: [TaggedFetchRequest],
        handlers: [PipelinedFetchPartHandler],
        channel: Channel,
        dispatcher: PipelinedCommandDispatcher,
        scheduledTimeout: Scheduled<Void>
    ) async throws {
        do {
            for request in tagToRequest {
                let command = FetchMessagePartCommand(identifier: request.uid, section: request.section)
                try await command.send(on: channel, tag: request.tag)
            }
        } catch {
            scheduledTimeout.cancel()
            responseBuffer.hasActiveHandler = false
            // Remove dispatcher BEFORE failing handlers to prevent double-resolve
            // from responses arriving while we fail handlers.
            try? await channel.pipeline.removeHandler(dispatcher)
            for handler in handlers {
                handler.fail(error)
            }
            throw error
        }
    }

    /// The outcome of draining every per-request future: the successful results plus
    /// the first ordinary failure and the first parser-limit violation, kept separate
    /// so the caller can apply policy (limit violations always throw; ordinary
    /// failures throw only when nothing succeeded, and recycle the connection when
    /// they indicate a bad channel).
    struct PipelinedFetchDrain {
        let results: [PipelinedFetchResult]
        let firstFailure: Error?
        /// The first failure whose class poisons the connection (timeout, channel
        /// drop). Tracked separately from `firstFailure` because failures are
        /// drained in send order: an early tagged NO must not mask a later
        /// timeout whose literals may still be streaming on the channel.
        let firstRecyclableFailure: Error?
        let firstLimitViolation: Error?
        /// A content-routing mismatch makes every result in the shared batch
        /// suspect, even if another request completed before it was detected.
        let firstRoutingViolation: Error?
        let failureCount: Int
    }

    /// Drains the per-request futures, tolerating individual failures.
    ///
    /// Swallowing a failed request and moving on is the point of pipelining: one bad UID
    /// must not sink the batch. Two classes of failure are still surfaced to the caller
    /// through the drain record:
    ///
    /// **Parser-limit violations** are not a property of one request — the peer sent more
    /// than we allow, and it poisons the shared decoder. Reported as an empty success, it
    /// looked to the caller exactly like "this message has no such section", and the
    /// connection stayed in use with a decoder that would raise the same error on the next
    /// read. The channel itself is closed by ``IMAPResponseLimitGuard`` when the violation
    /// happens; the drain record makes sure the caller is told rather than handed an
    /// empty array.
    ///
    /// **Ordinary failures** (timeout, channel drop, tagged NO/BAD) are recorded so the
    /// caller can rethrow when the whole batch failed — silently returning an empty array
    /// made a dead connection indistinguishable from a message with no sections — and
    /// recycle the connection when the error class calls for it.
    ///
    /// Every future is always awaited: leaving any unawaited would trip NIO's
    /// leaked-promise check.
    func drainPipelinedFetchFutures(
        tagToRequest: [TaggedFetchRequest],
        futures: [EventLoopFuture<Data>]
    ) async -> PipelinedFetchDrain {
        var results: [PipelinedFetchResult] = []
        var firstFailure: Error?
        var firstRecyclableFailure: Error?
        var limitViolation: Error?
        var routingViolation: Error?
        var failureCount = 0

        for (index, request) in tagToRequest.enumerated() {
            do {
                let data = try await futures[index].get()
                results.append(PipelinedFetchResult(uid: request.uid, section: request.section, data: data))
            } catch {
                failureCount += 1
                let uidValue = request.uid.value
                let sectionDescription = request.section.description
                if IMAPResponseLimitGuard.isLimitViolation(error) {
                    let message = "\(connectionContext) Pipelined fetch hit a parser limit on UID "
                        + "\(uidValue) section \(sectionDescription): \(error)"
                    logger.warning("\(message)")
                    if limitViolation == nil { limitViolation = error }
                } else {
                    logger.debug("Pipelined fetch failed for UID \(uidValue) section \(sectionDescription): \(error)")
                    if firstFailure == nil { firstFailure = error }
                    if routingViolation == nil, error is PipelinedFetchRoutingError {
                        routingViolation = error
                    } else if firstRecyclableFailure == nil, shouldRecycleConnection(for: error) {
                        firstRecyclableFailure = error
                    }
                }
            }
        }

        return PipelinedFetchDrain(
            results: results,
            firstFailure: firstFailure,
            firstRecyclableFailure: firstRecyclableFailure,
            firstLimitViolation: limitViolation,
            firstRoutingViolation: routingViolation,
            failureCount: failureCount
        )
    }
}
