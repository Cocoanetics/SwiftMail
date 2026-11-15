import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import Logging

extension IMAPConnection {
    @discardableResult func fetchCapabilities() async throws -> [Capability] {
        try await withOperation { [self] in
            let serverCapabilities = try await executeCommandBody(CapabilityCommand())
            let context = try capturedTransport()
            try commit(on: context) { context.capabilities = Set(serverCapabilities) }
            return serverCapabilities
        }
    }

    /// Replaces the capability snapshot with `reportedCapabilities`, or — when the
    /// server reported none — with the result of an explicit CAPABILITY command.
    /// Pass `useCommandBody: true` from call sites that already hold the command
    /// queue (mirrors `fetchNamespacesIfSupported(useCommandBody:)`).
    func refreshCapabilities(using reportedCapabilities: [Capability], useCommandBody: Bool = false) async throws {
        try validateOperation()
        if !reportedCapabilities.isEmpty {
            let context = try capturedTransport()
            try commit(on: context) { context.capabilities = Set(reportedCapabilities) }
            return
        }

        if useCommandBody {
            let refreshedCapabilities = try await executeCommandBody(CapabilityCommand())
            let context = try capturedTransport()
            try commit(on: context) { context.capabilities = Set(refreshedCapabilities) }
        } else {
            try await fetchCapabilities()
        }
    }

    func fetchNamespaces() async throws -> NamespaceResponse {
        try await withOperation { [self] in
            let response = try await executeCommandBody(NamespaceCommand())
            let context = try capturedTransport()
            try commit(on: context) { context.namespaces = response }
            return response
        }
    }

    func fetchNamespacesIfSupported(useCommandBody: Bool) async throws {
        try validateOperation()
        let namespaceCapability = Capability("NAMESPACE")
        guard capabilities.contains(namespaceCapability) else {
            let context = try capturedTransport()
            try commit(on: context) { context.namespaces = nil }
            return
        }

        do {
            let response: NamespaceResponse
            if useCommandBody {
                response = try await executeCommandBody(NamespaceCommand())
            } else {
                response = try await executeCommand(NamespaceCommand())
            }
            let context = try capturedTransport()
            try commit(on: context) { context.namespaces = response }
        } catch let error as CancellationError {
            throw error
        } catch {
            try validateOperation()
            if error is IMAPAbortReason { throw error }
            logger.warning("\(connectionContext) Failed to fetch namespace metadata: \(error)")
        }
    }

    func executeCommand<CommandType: IMAPCommand>(_ command: CommandType) async throws -> CommandType.ResultType {
        try await withOperation { [self] in
            try await self.executeCommandBody(command)
        }
    }

    func executeCommandBody<CommandType: IMAPCommand>(
        _ command: CommandType
    ) async throws -> CommandType.ResultType {
        try validateOperation()
        try command.validate()
        try await waitForIdleCompletionIfNeeded()
        try await recycleConnectionIfBufferedTerminationIfNeeded(operation: String(describing: CommandType.self))

        clearInvalidChannel()

        if self.channel == nil {
            try await reopenTransport(before: "sending command")
            try await reauthenticateIfSessionWasLost(before: String(describing: CommandType.self))
        }

        guard let channel = self.channel, channel.isActive else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }

        let context = try capturedTransport()
        guard context.channel === channel else { throw IMAPError.connectionFailed("Command transport replaced") }
        let tag = generateCommandTag()
        let resultPromise = channel.eventLoop.makePromise(of: CommandType.ResultType.self)
        handlerPromiseCreatedForTesting?()
        let handler = command.makeHandler(commandTag: tag, promise: resultPromise)
        let terminal = bindHandler(handler, promise: resultPromise, context: context)

        return try await runCommandHandler(
            CommandHandlerRun(
                command: command,
                context: context,
                channel: channel,
                tag: tag,
                handler: handler,
                resultPromise: resultPromise,
                terminal: terminal
            )
        )
    }

    private struct CommandHandlerRun<CommandType: IMAPCommand> {
        let command: CommandType
        let context: TransportContext
        let channel: Channel
        let tag: String
        let handler: CommandType.HandlerType
        let resultPromise: EventLoopPromise<CommandType.ResultType>
        let terminal: IMAPTerminal<CommandType.ResultType>
    }

    /// Arm a command's deadline. The timer is cancelled on the event loop the
    /// moment the result promise completes, so a response that arrived in time
    /// can never be followed by a timeout, even if the awaiting task resumes late.
    @discardableResult
    static func armCommandTimeout<ResultType: Sendable>(
        channel: Channel,
        timeoutSeconds: Int,
        promise: EventLoopPromise<ResultType>,
        logger: Logging.Logger
    ) -> Scheduled<Void> {
        let scheduled = channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            logger.warning("Command timed out after \(timeoutSeconds) seconds")
            // The caller never waits on the write (see `send`), so failing the
            // result wakes it; its timeout handling then recycles the connection,
            // which also fails a write still waiting for a `+`.
            promise.fail(IMAPError.timeout)
        }
        promise.futureResult.whenComplete { _ in scheduled.cancel() }
        return scheduled
    }

    private func runCommandHandler<CommandType: IMAPCommand>(
        _ run: CommandHandlerRun<CommandType>
    ) async throws -> CommandType.ResultType {
        let channel = run.channel
        let tag = run.tag
        let handler = run.handler
        let resultPromise = run.resultPromise
        let context = run.context
        let responseBuffer = context.responseBuffer
        let duplexLogger = context.duplexLogger
        let terminal = run.terminal
        // The timeout measures the SERVER. It is armed by `send`'s `whenWritten`
        // callback, in the same event-loop task that emits the command, so no
        // local delay — installing the handler, building an APPEND payload, a
        // busy cooperative pool or event loop, other work queued between the
        // write and the arming — is counted, and none can stretch the deadline.
        // Arming it earlier let a server that answered instantly still "time
        // out", seen live on Gmail's post-LOGIN NAMESPACE. The timer cancels
        // itself when the result is set, including a result set before it.
        // Touched only on the event loop: whether the command's last write had
        // settled when the result failed. Recorded as the failure happens, since
        // a `+` in the same read can complete the write before we resume.
        let writeState = WriteState()
        resultPromise.futureResult.whenFailure { _ in writeState.failedWithWritePending = !writeState.settled }
        do {
            try await installHandler(handler, terminal: terminal, context: context)
            try await lifecycleCheckpoint("write:\(String(describing: CommandType.self))", context: context)
            try await sendCommand(run, terminal: terminal, writeState: writeState)
            // A close that raced the handler's installation may have been
            // delivered before the handler was added; don't wait out the deadline.
            if !channel.isActive {
                terminal.complete(.failure(IMAPError.connectionFailed("Connection closed before command completed")))
            }
            let result = try await terminal.value()
            try await lifecycleCheckpoint("response:\(String(describing: CommandType.self))", context: context)

            responseBuffer.hasActiveHandler = false

            await handleConnectionTerminationInResponses(handler.untaggedResponses, context: context)
            duplexLogger.flushInboundBuffer()

            return result
        } catch let caught {
            responseBuffer.hasActiveHandler = false

            // Ensure the promise is always resolved — prevents NIO "leaking promise" fatal error
            // when the channel becomes inactive between the guard and pipeline operations.
            terminal.complete(.failure(caught))
            // If the timeout fired first, report it rather than the write it aborted.
            var error = caught
            do { _ = try await terminal.value() } catch let settled { error = settled }

            await handleConnectionTerminationInResponses(handler.untaggedResponses, context: context)
            duplexLogger.flushInboundBuffer()
            if !handler.isCompleted {
                try? await channel.pipeline.removeHandler(handler)
            }
            logErrorDiagnostics(error: error, operation: "command \(String(describing: CommandType.self)) [\(tag)]")
            // A result that failed while its write is still pending (a literal
            // awaiting `+`) leaves NIOIMAP mid-command: the next command would
            // queue behind it. Recycle, whatever the error.
            let writePending = (try? await channel.eventLoop.submit { writeState.failedWithWritePending }.get())
                ?? false
            if writePending || shouldRecycleConnection(for: error) {
                await closeTransport(context)
            }
            throw error
        }
    }

    private func sendCommand<CommandType: IMAPCommand>(
        _ run: CommandHandlerRun<CommandType>, terminal: IMAPTerminal<CommandType.ResultType>, writeState: WriteState
    ) async throws {
        let channel = run.channel
        let context = run.context
        let timeoutSeconds = run.command.timeoutSeconds
        let logger = self.logger
        let token = operationToken
        try await IMAPWriteScope.$validate.withValue({ [self] in
            try validateTransport(context, token: token)
        }, operation: {
            try await run.command.send(on: channel, tag: run.tag) { lastWrite in
                let timer = channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
                    if terminal.complete(.failure(IMAPError.timeout)) {
                        logger.warning("Command timed out after \(timeoutSeconds) seconds")
                    }
                }
                terminal.attachTimer(timer, on: channel.eventLoop)
                lastWrite.whenComplete { _ in writeState.settled = true }
            }
        })
    }

    func executeHandlerOnly<T: Sendable, HandlerType: IMAPCommandHandler>(
        handlerType: HandlerType.Type,
        timeoutSeconds: Int = 5
    ) async throws -> T where HandlerType.ResultType == T {
        try validateOperation()
        try await recycleConnectionIfBufferedTerminationIfNeeded(operation: String(describing: HandlerType.self))
        clearInvalidChannel()

        if self.channel == nil {
            try await reopenTransport(before: "executing handler")
        }

        guard let channel = self.channel, channel.isActive else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }

        let context = try capturedTransport()
        guard context.channel === channel else { throw IMAPError.connectionFailed("Handler transport replaced") }
        let resultPromise = channel.eventLoop.makePromise(of: T.self)
        handlerPromiseCreatedForTesting?()
        let handler = HandlerType.init(commandTag: "", promise: resultPromise)
        let terminal = bindHandler(handler, promise: resultPromise, context: context)
        let scheduledTask = scheduleHandlerTimeout(
            channel: channel,
            timeoutSeconds: timeoutSeconds,
            terminal: terminal
        )

        return try await runStandaloneHandler(
            handler: handler,
            channel: channel,
            context: context,
            terminal: terminal,
            scheduledTask: scheduledTask
        )
    }

    private func scheduleHandlerTimeout<ResultType: Sendable>(
        channel: Channel,
        timeoutSeconds: Int,
        terminal: IMAPTerminal<ResultType>
    ) -> Scheduled<Void> {
        let logger = self.logger
        return channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            logger.warning("Handler execution timed out after \(timeoutSeconds) seconds")
            terminal.complete(.failure(IMAPError.timeout))
        }
    }

    private func runStandaloneHandler<T: Sendable, HandlerType: IMAPCommandHandler>(
        handler: HandlerType,
        channel: Channel,
        context: TransportContext,
        terminal: IMAPTerminal<T>,
        scheduledTask: Scheduled<Void>
    ) async throws -> T where HandlerType.ResultType == T {
        let responseBuffer = context.responseBuffer
        let duplexLogger = context.duplexLogger
        terminal.attachTimer(scheduledTask, on: channel.eventLoop)
        do {
            try await installHandler(handler, terminal: terminal, context: context)
            let result = try await terminal.value()
            try validateTransport(context)

            scheduledTask.cancel()
            responseBuffer.hasActiveHandler = false

            await handleConnectionTerminationInResponses(handler.untaggedResponses, context: context)
            duplexLogger.flushInboundBuffer()

            return result
        } catch {
            scheduledTask.cancel()
            responseBuffer.hasActiveHandler = false

            // Ensure the promise is always resolved — prevents NIO "leaking promise" fatal error
            // when the channel becomes inactive between the guard and pipeline operations.
            terminal.complete(.failure(error))

            await handleConnectionTerminationInResponses(handler.untaggedResponses, context: context)
            duplexLogger.flushInboundBuffer()
            if !handler.isCompleted {
                try? await channel.pipeline.removeHandler(handler)
            }
            logErrorDiagnostics(error: error, operation: "handler \(String(describing: HandlerType.self))")
            if shouldRecycleConnection(for: error) {
                await closeTransport(context)
            }
            throw error
        }
    }

    func generateCommandTag() -> String {
        let tagPrefix = "A"
        commandTagCounter += 1
        return "\(tagPrefix)\(String(format: "%03d", commandTagCounter))"
    }
}

/// Whether a command's last write has settled, and whether its result failed
/// before that; read and written only on the channel's event loop.
private final class WriteState: @unchecked Sendable {
    var settled = false
    var failedWithWritePending = false
}
