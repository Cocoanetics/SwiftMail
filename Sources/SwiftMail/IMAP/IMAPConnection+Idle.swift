import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

extension IMAPConnection {
    func idle() async throws -> AsyncStream<IMAPServerEvent> {
        var continuationRef: AsyncStream<IMAPServerEvent>.Continuation!
        let stream = AsyncStream<IMAPServerEvent> { continuation in
            continuationRef = continuation
        }

        guard let continuation = continuationRef else {
            throw IMAPError.commandFailed("Failed to start IDLE session")
        }

        try await withOperation { [self] in
            try await self.startIdleSession(continuation: continuation)
        }

        return stream
    }

    func startIdleSession(continuation: AsyncStream<IMAPServerEvent>.Continuation) async throws {
        try validateOperation()
        if !capabilities.contains(.idle) {
            throw IMAPError.commandNotSupported("IDLE command not supported by server")
        }

        guard idleHandler == nil else {
            throw IMAPError.commandFailed("IDLE session already active")
        }

        try await recycleConnectionIfBufferedTerminationIfNeeded(operation: "IDLE start")
        clearInvalidChannel()

        if self.channel == nil {
            try await reopenTransport(before: "starting IDLE")
            try await reauthenticateIfSessionWasLost(before: "IDLE")
        }

        guard let channel = self.channel, channel.isActive else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }

        let context = try capturedTransport()
        guard context.channel === channel else { throw IMAPError.connectionFailed("IDLE transport replaced") }
        let responseBuffer = context.responseBuffer
        let tag = generateCommandTag()
        let promise = channel.eventLoop.makePromise(of: Void.self)
        handlerPromiseCreatedForTesting?()
        let handler = IdleHandler(commandTag: tag, promise: promise, continuation: continuation)
        let terminal = bindHandler(handler, promise: promise, context: context)

        do {
            try commit(on: context) {
                context.idleHandler = handler
                context.idleTerminationInProgress = false
            }
            try await installIdleHandler(handler, terminal: terminal, context: context)
            try await sendIdleStart(tag: tag, terminal: terminal, context: context)
            try validateTransport(context)
        } catch {
            responseBuffer.hasActiveHandler = false
            try? commit(on: context) { context.idleHandler = nil }
            // Ensure the promise is resolved to prevent NIO "leaking promise" fatal error
            terminal.complete(.failure(error))
            handler.finishStream()
            if !handler.isCompleted {
                try? await channel.pipeline.removeHandler(handler)
            }
            logErrorDiagnostics(error: error, operation: "IDLE start")
            if shouldRecycleConnection(for: error) {
                await closeTransport(context)
            }
            throw error
        }
    }

    private func sendIdleStart(tag: String, terminal: IMAPTerminal<Void>, context: TransportContext) async throws {
        let channel = context.channel
        let tagged = IdleCommand().toTaggedCommand(tag: tag)
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        let token = operationToken
        try await channel.eventLoop.flatSubmit {
            do {
                try self.validateTransport(context, token: token)
                let write = channel.writeAndFlush(wrapped)
                write.whenFailure { terminal.complete(.failure($0)) }
                return write
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }.get()
    }

    private func installIdleHandler(
        _ handler: IdleHandler, terminal: IMAPTerminal<Void>, context: TransportContext
    ) async throws {
        let channel = context.channel
        let installed: EventLoopFuture<Void> = channel.pipeline.addHandler(
            handler, position: .before(context.responseBuffer))
        terminal.attachHandlerCleanup(after: installed) {
            handler.finishStream()
            channel.pipeline.removeHandler(handler, promise: nil)
            context.responseBuffer.hasActiveHandler = false
        }
        try await installed.get()
        try validateTransport(context)
        context.responseBuffer.hasActiveHandler = true
    }

    func waitForIdleCompletionIfNeeded(timeoutSeconds: TimeInterval = 15) async throws {
        try validateOperation()
        guard let handler = idleHandler else { return }
        let context = try capturedTransport()
        do {
            try await waitForIdleHandlerCompletion(handler, timeoutSeconds: timeoutSeconds)
        } catch {
            let warning = "\(connectionContext) IDLE handler did not complete in time; "
                + "resetting connection before continuing"
            logger.warning("\(warning)")
            context.responseBuffer.hasActiveHandler = false
            await closeTransport(context)
            throw error
        }
    }

    func waitForIdleStartIfNeeded(_ handler: IdleHandler, timeoutSeconds: TimeInterval) async throws {
        let context = try capturedTransport()
        guard !handler.hasEnteredIdleState else { return }

        let pollIntervalNanos: UInt64 = 25_000_000 // 25ms
        let timeout = max(timeoutSeconds, TimeInterval(minimumCommandTimeoutSeconds))
        let start = Date()
        while !handler.hasEnteredIdleState {
            try validateTransport(context)
            if Task.isCancelled {
                throw CancellationError()
            }

            if Date().timeIntervalSince(start) >= timeout {
                throw IMAPError.timeout
            }

            if !context.channel.isActive {
                throw IMAPError.connectionFailed("Channel became inactive before IDLE confirmation")
            }

            try? await Task.sleep(nanoseconds: pollIntervalNanos)
        }
    }

    func waitForIdleHandlerCompletion(_ handler: IdleHandler, timeoutSeconds: TimeInterval) async throws {
        _ = try await waitForFutureWithTimeout(handler.promise.futureResult, timeoutSeconds: timeoutSeconds)
    }

    func waitForFutureWithTimeout<T: Sendable>(
        _ future: EventLoopFuture<T>,
        timeoutSeconds: TimeInterval
    ) async throws -> T {
        if Task.isCancelled {
            throw CancellationError()
        }

        let timeout = max(timeoutSeconds, TimeInterval(minimumCommandTimeoutSeconds), 0.1)
        let timeoutMilliseconds = max(Int64(timeout * 1_000), 100)
        let (_, terminal) = lifetime.registerOperation(of: T.self, parent: operationToken)
        let timeoutTask = future.eventLoop.scheduleTask(in: .milliseconds(timeoutMilliseconds)) {
            _ = terminal.complete(.failure(IMAPError.timeout))
        }

        terminal.attachTimer(timeoutTask, on: future.eventLoop)
        future.whenComplete { terminal.complete($0) }
        return try await terminal.value()
    }
}
