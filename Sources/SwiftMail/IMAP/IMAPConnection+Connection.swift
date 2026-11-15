import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOSSL

extension IMAPConnection {
    func doneBody(timeoutSeconds: TimeInterval = 15) async throws {
        try validateOperation()
        guard let handler = idleHandler else {
            logger.debug("\(connectionContext) No active IDLE session, skipping DONE command")
            return
        }
        let context = try capturedTransport()
        let responseBuffer = context.responseBuffer

        if try await handleAmbiguousIdleCompletion(handler: handler, context: context) {
            return
        }

        guard try await resolveActiveChannelForDone(context) != nil else {
            return
        }

        guard !idleTerminationInProgress else {
            try await waitForIdleHandlerCompletion(handler, timeoutSeconds: timeoutSeconds)
            return
        }

        try commit(on: context) { context.idleTerminationInProgress = true }

        defer {
            try? commit(on: context) {
                context.idleTerminationInProgress = false
                context.idleHandler = nil
            }
            responseBuffer.hasActiveHandler = false
        }

        try await performIdleDone(handler: handler, context: context, timeoutSeconds: timeoutSeconds)
    }

    private func handleAmbiguousIdleCompletion(handler: IdleHandler, context: TransportContext) async throws -> Bool {
        try validateTransport(context)
        guard handler.isCompleted else { return false }
        let warning = "\(connectionContext) IDLE already completed before DONE; "
            + "forcing reconnect due to ambiguous IDLE completion state"
        logger.warning("\(warning)")
        context.responseBuffer.hasActiveHandler = false
        await closeTransport(context)
        throw IMAPError.connectionFailed(
            "Ambiguous IDLE completion detected before DONE; connection recycled to resynchronize IMAP state"
        )
    }

    private func resolveActiveChannelForDone(_ context: TransportContext) async throws -> Channel? {
        try validateTransport(context)
        let responseBuffer = context.responseBuffer
        guard context.channel.isActive else {
            let terminationReasons = responseBuffer.consumeBufferedConnectionTerminationReasons()
            if !terminationReasons.isEmpty {
                let reason = terminationReasons.joined(separator: " | ")
                logger.info("\(connectionContext) Skipping DONE because server already closed connection: \(reason)")
                try commit(on: context) { context.idleHandler = nil }
                responseBuffer.hasActiveHandler = false
                return nil
            }

            logger.warning("\(connectionContext) Cannot send DONE because channel is not active")
            try commit(on: context) { context.idleHandler = nil }
            responseBuffer.hasActiveHandler = false
            throw IMAPError.connectionFailed("Channel is not active")
        }
        return context.channel
    }

    private func performIdleDone(
        handler: IdleHandler,
        context: TransportContext,
        timeoutSeconds: TimeInterval
    ) async throws {
        let channel = context.channel
        let duplexLogger = context.duplexLogger
        do {
            try await waitForIdleStartIfNeeded(handler, timeoutSeconds: min(timeoutSeconds, 5))
            try validateTransport(context)
            let token = operationToken
            let write = channel.eventLoop.flatSubmit {
                do {
                    try self.validateTransport(context, token: token)
                    return channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.idleDone))
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }
            _ = try await waitForFutureWithTimeout(
                write,
                timeoutSeconds: timeoutSeconds
            )
            try await waitForIdleHandlerCompletion(handler, timeoutSeconds: timeoutSeconds)
        } catch {
            duplexLogger.flushInboundBuffer()

            if error is CancellationError {
                logger.warning("\(connectionContext) IDLE termination was cancelled; recycling connection")
                await closeTransport(context)
                throw error
            }

            if handler.isCompleted {
                try await requireTaggedIdleCompletion(handler, context: context)
                throw error
            }

            logErrorDiagnostics(error: error, operation: "DONE")

            if let imapError = error as? IMAPError, case .timeout = imapError {
                logger.warning("\(connectionContext) Timed out waiting for IDLE termination after DONE")
            } else {
                logger.warning("\(connectionContext) Failed to terminate IDLE after DONE: \(error)")
            }

            await closeTransport(context)
            throw error
        }

        try await requireTaggedIdleCompletion(handler, context: context)
        duplexLogger.flushInboundBuffer()
    }

    private func requireTaggedIdleCompletion(_ handler: IdleHandler, context: TransportContext) async throws {
        try validateTransport(context)
        guard handler.completedWithTaggedResponse else {
            let reason = handler.completionReason?.rawValue ?? "unknown"
            let warning = "\(connectionContext) IDLE completed without tagged completion "
                + "during DONE (reason=\(reason)); recycling connection"
            logger.warning("\(warning)")
            await closeTransport(context)
            throw IMAPError.connectionFailed(
                "IDLE completed without tagged completion during DONE; connection recycled"
            )
        }
    }

    func disconnectBody() async throws {
        try validateOperation()
        guard let context = try? capturedTransport() else { return }
        await closeTransport(context)
    }

    /// Public disconnect bypasses command admission, including task cancellation.
    /// Keep the queued internal disconnect for graceful shutdown and IDLE recovery.
    func disconnectImmediately() async throws {
        try validateOperation()
        let failure = IMAPError.connectionFailed("Connection closed by disconnect")
        let snapshot = lifetime.gate.withLock { () -> ([TransportContext], [IMAPLifetimeGate.Action]) in
            let attempts = Array(bootstrapAttempts.values)
            let candidates = attempts.flatMap(\.candidates)
            let contexts = (transport.map { [$0] } ?? []) + candidates
            let uniqueContexts = Dictionary(uniqueKeysWithValues: contexts.map { ($0.id, $0) })
            let actions = attempts.flatMap {
                ($0.tcp.settleLocked(.failure(failure)) ?? [])
                    + ($0.greeting.settleLocked(.failure(failure)) ?? [])
            }
            transport = nil
            bootstrapAttempts.removeAll()
            sessionWasLost = false
            stagingCapabilities = []
            stagingBuffer = UntaggedResponseBuffer()
            stagingLogger = makeDuplexLogger()
            for context in uniqueContexts.values {
                closingTransports[context.id] = context
            }
            return (Array(uniqueContexts.values), actions)
        }
        // Initiate every captured close before a continuation can resume or this
        // method reaches its first suspension.
        for context in snapshot.0 { context.channel.close(promise: nil) }
        for action in snapshot.1 { action() }
        for context in snapshot.0 {
            await beforeTransportCloseForTesting?(context)
            try? await context.channel.closeFuture.get()
            _ = lifetime.gate.withLock { closingTransports.removeValue(forKey: context.id) }
        }
    }

    func closeTransport(_ context: TransportContext) async {
        lifetime.gate.withLock {
            closingTransports[context.id] = context
            if transport === context {
                if context.authenticated { sessionWasLost = true }
                transport = nil
                stagingCapabilities = []
                stagingBuffer = UntaggedResponseBuffer()
                stagingLogger = makeDuplexLogger()
            }
        }
        await beforeTransportCloseForTesting?(context)
        try? await context.channel.close().get()
        _ = lifetime.gate.withLock { closingTransports.removeValue(forKey: context.id) }
    }

    /// Reopens the transport a command found gone, the reconnect a command runs inside
    /// itself. Throws instead, opening nothing, when `reconnectsInsideCommands` is off:
    /// the caller then learns the session it was using has ended and reconnects on
    /// purpose with `connect()`, which this switch never blocks.
    func reopenTransport(before operation: String) async throws {
        try validateOperation()
        guard reconnectsInsideCommands else {
            logger.info(
                "\(connectionContext) Channel is nil; reconnecting inside commands is off, failing \(operation)"
            )
            throw IMAPError.connectionFailed(
                "Connection lost before \(operation); reconnecting inside commands is turned off"
            )
        }
        logger.info("\(connectionContext) Channel is nil, re-establishing connection before \(operation)")
        try await connectBody()
    }

    func clearInvalidChannel() {
        lifetime.gate.withLock {
            if let token = operationToken, (try? lifetime.validateLocked(token)) == nil { return }
            if let context = transport, !context.channel.isActive {
                if context.authenticated { sessionWasLost = true }
                stagingCapabilities = context.capabilities
                transport = nil
                stagingBuffer = UntaggedResponseBuffer()
                stagingLogger = makeDuplexLogger()
            }
        }
    }

    func recycleConnectionIfBufferedTerminationIfNeeded(operation: String) async throws {
        try validateOperation()
        guard let context = try? capturedTransport(),
              context.responseBuffer.hasBufferedConnectionTermination else { return }
        let reasons = context.responseBuffer.consumeBufferedConnectionTerminationReasons()
        let reasonSummary = reasons.isEmpty ? "<unknown>" : reasons.joined(separator: " | ")
        let warning = "\(connectionContext) Buffered BYE/fatal detected before \(operation). "
            + "Recycling connection. reasons=\(reasonSummary)"
        logger.warning("\(warning)")
        await closeTransport(context)
    }

    func shouldRecycleConnection(for error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        if let imapError = error as? IMAPError {
            switch imapError {
                case .connectionFailed, .timeout:
                    return true
                default:
                    break
            }
        }

        // The IMAP client state machine rejected the exchange (e.g. a tagged reply
        // where a literal's `+` was due): the protocol state is unknown, and a
        // command may be half written.
        if error is UnexpectedResponse || error is UnexpectedContinuationRequest {
            return true
        }

        if let partialError = error as? PartialFetchError,
           case .invalidResponse = partialError {
            return true
        }

        // The handler already closed the channel; retire the captured transport with it.
        if error is FetchReceiveLimitExceededError {
            return true
        }

        // Raw NIO transport failure (e.g. writeAndFlush on a closed channel). The substring
        // check below misses most ChannelError cases — `String(describing:)` returns just the
        // case name (`alreadyClosed`, `ioOnClosedChannel`, `connectPending`, `inputClosed`,
        // `outputClosed`), none of which match the literals we look for. Without this guard
        // the dead channel stays in `self.channel` and the next command hits the same socket.
        if error is ChannelError {
            return true
        }

        return errorDescriptionIndicatesRecycle(error)
    }

    private func errorDescriptionIndicatesRecycle(_ error: Error) -> Bool {
        let description = String(describing: error).lowercased()
        return description.contains("decodererror")
            || description.contains("parsererror")
            || description.contains("channel is not active")
            || description.contains("connection reset by peer")
            || description.contains("broken pipe")
            || description.contains("eof")
            || description.contains("invalid state")
    }

    func logErrorDiagnostics(error: Error, operation: String) {
        let active = channel?.isActive ?? false
        let diagnostics = """
        \(connectionContext) \(operation) failed: \(error); \
        channelActive=\(active) authenticated=\(isSessionAuthenticated) \
        idleHandlerActive=\(idleHandler != nil) idleTerminationInProgress=\(idleTerminationInProgress) \
        bufferedResponses=\(responseBuffer.bufferedCount) \
        bufferedTermination=\(responseBuffer.hasBufferedConnectionTermination)
        """
        logger.error("\(diagnostics)")
    }
}
