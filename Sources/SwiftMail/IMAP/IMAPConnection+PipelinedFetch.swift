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

    /// Execute multiple FETCH BODY[section] commands in a pipelined burst.
    /// Sends all commands without awaiting individual responses (RFC 3501 §5.5).
    /// The PipelinedCommandDispatcher routes responses to the correct handler by tag.
    /// All commands execute under a single commandQueue lock — no interleaving.
    ///
    /// - Parameter requests: Array of (uid, section) pairs to fetch.
    /// - Parameter timeoutSeconds: Timeout for the entire batch.
    /// - Returns: Array of results with fetched data per (uid, section).
    /// - Throws: If the connection is unavailable or all commands fail.
    func executePipelinedFetchParts(
        requests: [(uid: UID, section: Section)],
        timeoutSeconds: Int = 60
    ) async throws -> [PipelinedFetchResult] {
        guard !requests.isEmpty else { return [] }

        return try await commandQueue.run { [self] in
            try await self.pipelinedFetchPartsBody(requests: requests, timeoutSeconds: timeoutSeconds)
        }
    }

    private func pipelinedFetchPartsBody(
        requests: [(uid: UID, section: Section)],
        timeoutSeconds: Int
    ) async throws -> [PipelinedFetchResult] {
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

        try await dispatchPipelinedFetchCommands(
            tagToRequest: registered.tagToRequest,
            handlers: registered.handlers,
            channel: channel,
            dispatcher: dispatcher,
            scheduledTimeout: scheduledTimeout
        )

        let results = await collectPipelinedFetchResults(
            tagToRequest: registered.tagToRequest,
            futures: registered.futures
        )

        scheduledTimeout.cancel()
        responseBuffer.hasActiveHandler = false
        duplexLogger.flushInboundBuffer()

        // Remove dispatcher — may already be removed if channelInactive fired
        try? await channel.pipeline.removeHandler(dispatcher)

        if results.count != requests.count || !channel.isActive {
            try? await disconnectBody()
        }

        return results
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
            dispatcher.register(tag: tag, handler: handler)
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
            try? await disconnectBody()
            throw error
        }
    }

    private func collectPipelinedFetchResults(
        tagToRequest: [TaggedFetchRequest],
        futures: [EventLoopFuture<Data>]
    ) async -> [PipelinedFetchResult] {
        var results: [PipelinedFetchResult] = []

        for (index, request) in tagToRequest.enumerated() {
            do {
                let data = try await futures[index].get()
                results.append(PipelinedFetchResult(uid: request.uid, section: request.section, data: data))
            } catch {
                let uidValue = request.uid.value
                let sectionDescription = request.section.description
                logger.debug("Pipelined fetch failed for UID \(uidValue) section \(sectionDescription): \(error)")
            }
        }

        return results
    }
}
