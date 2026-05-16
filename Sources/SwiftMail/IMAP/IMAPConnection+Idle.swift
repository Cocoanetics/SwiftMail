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

        try await commandQueue.run { [self] in
            try await self.startIdleSession(continuation: continuation)
        }

        return stream
    }

    func startIdleSession(continuation: AsyncStream<IMAPServerEvent>.Continuation) async throws {
        if !capabilities.contains(.idle) {
            throw IMAPError.commandNotSupported("IDLE command not supported by server")
        }

        guard idleHandler == nil else {
            throw IMAPError.commandFailed("IDLE session already active")
        }

        idleTerminationInProgress = false
        try await recycleConnectionIfBufferedTerminationIfNeeded(operation: "IDLE start")
        clearInvalidChannel()

        if self.channel == nil {
            logger.info("\(connectionContext) Channel is nil, re-establishing connection before starting IDLE")
            try await connectBody()
        }

        guard let channel = self.channel, channel.isActive else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }

        let promise = channel.eventLoop.makePromise(of: Void.self)
        let tag = generateCommandTag()
        let handler = IdleHandler(commandTag: tag, promise: promise, continuation: continuation)
        idleHandler = handler

        do {
            try await channel.pipeline.addHandler(handler, position: .before(responseBuffer)).get()
            responseBuffer.hasActiveHandler = true
            let command = IdleCommand()
            let tagged = command.toTaggedCommand(tag: tag)
            let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
            try await channel.writeAndFlush(wrapped).get()
        } catch {
            responseBuffer.hasActiveHandler = false
            idleHandler = nil
            // Ensure the promise is resolved to prevent NIO "leaking promise" fatal error
            promise.fail(error)
            if !handler.isCompleted {
                try? await channel.pipeline.removeHandler(handler)
            }
            logErrorDiagnostics(error: error, operation: "IDLE start")
            if shouldRecycleConnection(for: error) {
                try? await disconnectBody()
            }
            throw error
        }
    }

    func waitForIdleCompletionIfNeeded(timeoutSeconds: TimeInterval = 15) async throws {
        guard let handler = idleHandler else { return }
        do {
            try await waitForIdleHandlerCompletion(handler, timeoutSeconds: timeoutSeconds)
        } catch {
            let warning = "\(connectionContext) IDLE handler did not complete in time; "
                + "resetting connection before continuing"
            logger.warning("\(warning)")
            idleHandler = nil
            responseBuffer.hasActiveHandler = false
            try? await disconnectBody()
            throw error
        }
    }

    func waitForIdleStartIfNeeded(_ handler: IdleHandler, timeoutSeconds: TimeInterval) async throws {
        guard !handler.hasEnteredIdleState else { return }

        let pollIntervalNanos: UInt64 = 25_000_000 // 25ms
        let start = Date()
        while !handler.hasEnteredIdleState {
            if Task.isCancelled {
                throw CancellationError()
            }

            if Date().timeIntervalSince(start) >= timeoutSeconds {
                throw IMAPError.timeout
            }

            if self.channel?.isActive != true {
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

        let timeout = max(timeoutSeconds, 0.1)
        let timeoutMilliseconds = max(Int64(timeout * 1_000), 100)
        let timeoutPromise = future.eventLoop.makePromise(of: T.self)
        let timeoutTask = future.eventLoop.scheduleTask(in: .milliseconds(timeoutMilliseconds)) {
            timeoutPromise.fail(IMAPError.timeout)
        }

        defer { timeoutTask.cancel() }

        future.cascade(to: timeoutPromise)
        return try await timeoutPromise.futureResult.get()
    }
}
