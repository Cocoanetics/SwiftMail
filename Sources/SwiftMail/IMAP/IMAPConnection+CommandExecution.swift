import Foundation
import NIO
@preconcurrency import NIOIMAP
import NIOIMAPCore

extension IMAPConnection {
    @discardableResult func fetchCapabilities() async throws -> [Capability] {
        let command = CapabilityCommand()
        let serverCapabilities = try await executeCommand(command)
        capabilities = Set(serverCapabilities)
        return serverCapabilities
    }

    func refreshCapabilities(using reportedCapabilities: [Capability]) async throws {
        if !reportedCapabilities.isEmpty {
            capabilities = Set(reportedCapabilities)
            return
        }

        try await fetchCapabilities()
    }

    func fetchNamespaces() async throws -> NamespaceResponse {
        let response = try await executeCommand(NamespaceCommand())
        namespaces = response
        return response
    }

    func fetchNamespacesIfSupported(useCommandBody: Bool) async {
        let namespaceCapability = Capability("NAMESPACE")
        guard capabilities.contains(namespaceCapability) else {
            namespaces = nil
            return
        }

        do {
            if useCommandBody {
                namespaces = try await executeCommandBody(NamespaceCommand())
            } else {
                namespaces = try await executeCommand(NamespaceCommand())
            }
        } catch {
            logger.warning("\(connectionContext) Failed to fetch namespace metadata: \(error)")
        }
    }

    func executeCommand<CommandType: IMAPCommand>(_ command: CommandType) async throws -> CommandType.ResultType {
        try await commandQueue.run { [self] in
            try await executeCommandBody(command)
        }
    }

    func executeCommandBody<CommandType: IMAPCommand>(
        _ command: CommandType
    ) async throws -> CommandType.ResultType {
        try command.validate()
        try await waitForIdleCompletionIfNeeded()
        try await recycleConnectionIfBufferedTerminationIfNeeded(operation: String(describing: CommandType.self))

        clearInvalidChannel()

        if self.channel == nil {
            logger.info("\(connectionContext) Channel is nil, re-establishing connection before sending command")
            try await connectBody()
        }

        guard let channel, channel.isActive else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }

        let resultPromise = channel.eventLoop.makePromise(of: CommandType.ResultType.self)
        let tag = generateCommandTag()
        let handler = CommandType.HandlerType(commandTag: tag, promise: resultPromise)
        let scheduledTask = scheduleCommandTimeout(
            channel: channel,
            timeoutSeconds: command.timeoutSeconds,
            promise: resultPromise
        )

        return try await runCommandHandler(
            CommandHandlerRun(
                command: command,
                channel: channel,
                tag: tag,
                handler: handler,
                resultPromise: resultPromise,
                scheduledTask: scheduledTask
            )
        )
    }

    private struct CommandHandlerRun<CommandType: IMAPCommand> {
        let command: CommandType
        let channel: Channel
        let tag: String
        let handler: CommandType.HandlerType
        let resultPromise: EventLoopPromise<CommandType.ResultType>
        let scheduledTask: Scheduled<Void>
    }

    private func scheduleCommandTimeout(
        channel: Channel,
        timeoutSeconds: Int,
        promise: EventLoopPromise<some Sendable>
    ) -> Scheduled<Void> {
        let logger = logger
        return channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            logger.warning("Command timed out after \(timeoutSeconds) seconds")
            promise.fail(IMAPError.timeout)
        }
    }

    private func runCommandHandler<CommandType: IMAPCommand>(
        _ run: CommandHandlerRun<CommandType>
    ) async throws -> CommandType.ResultType {
        let command = run.command
        let channel = run.channel
        let tag = run.tag
        let handler = run.handler
        let resultPromise = run.resultPromise
        let scheduledTask = run.scheduledTask
        do {
            try await channel.pipeline.addHandler(handler, position: .before(responseBuffer)).get()
            responseBuffer.hasActiveHandler = true
            try await command.send(on: channel, tag: tag)
            let result = try await resultPromise.futureResult.get()

            scheduledTask.cancel()
            responseBuffer.hasActiveHandler = false

            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            duplexLogger.flushInboundBuffer()

            return result
        } catch {
            scheduledTask.cancel()
            responseBuffer.hasActiveHandler = false

            // Ensure the promise is always resolved — prevents NIO "leaking promise" fatal error
            // when the channel becomes inactive between the guard and pipeline operations.
            resultPromise.fail(error)

            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            duplexLogger.flushInboundBuffer()
            if !handler.isCompleted {
                try? await channel.pipeline.removeHandler(handler)
            }
            logErrorDiagnostics(error: error, operation: "command \(String(describing: CommandType.self)) [\(tag)]")
            if shouldRecycleConnection(for: error) {
                try? await disconnectBody()
            }
            throw error
        }
    }

    func executeHandlerOnly<T: Sendable, HandlerType: IMAPCommandHandler>(
        handlerType _: HandlerType.Type,
        timeoutSeconds: Int = 5
    ) async throws -> T where HandlerType.ResultType == T {
        try await recycleConnectionIfBufferedTerminationIfNeeded(operation: String(describing: HandlerType.self))
        clearInvalidChannel()

        if self.channel == nil {
            logger.info("\(connectionContext) Channel is nil, re-establishing connection before executing handler")
            try await connectBody()
        }

        guard let channel, channel.isActive else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }

        let resultPromise = channel.eventLoop.makePromise(of: T.self)
        let handler = HandlerType(commandTag: "", promise: resultPromise)
        let scheduledTask = scheduleHandlerTimeout(
            channel: channel,
            timeoutSeconds: timeoutSeconds,
            promise: resultPromise
        )

        return try await runStandaloneHandler(
            handler: handler,
            channel: channel,
            resultPromise: resultPromise,
            scheduledTask: scheduledTask
        )
    }

    private func scheduleHandlerTimeout(
        channel: Channel,
        timeoutSeconds: Int,
        promise: EventLoopPromise<some Sendable>
    ) -> Scheduled<Void> {
        let logger = logger
        return channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            logger.warning("Handler execution timed out after \(timeoutSeconds) seconds")
            promise.fail(IMAPError.timeout)
        }
    }

    private func runStandaloneHandler<T: Sendable, HandlerType: IMAPCommandHandler>(
        handler: HandlerType,
        channel: Channel,
        resultPromise: EventLoopPromise<T>,
        scheduledTask: Scheduled<Void>
    ) async throws -> T where HandlerType.ResultType == T {
        do {
            try await channel.pipeline.addHandler(handler, position: .before(responseBuffer)).get()
            responseBuffer.hasActiveHandler = true
            let result = try await resultPromise.futureResult.get()

            scheduledTask.cancel()
            responseBuffer.hasActiveHandler = false

            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            duplexLogger.flushInboundBuffer()

            return result
        } catch {
            scheduledTask.cancel()
            responseBuffer.hasActiveHandler = false

            // Ensure the promise is always resolved — prevents NIO "leaking promise" fatal error
            // when the channel becomes inactive between the guard and pipeline operations.
            resultPromise.fail(error)

            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            duplexLogger.flushInboundBuffer()
            if !handler.isCompleted {
                try? await channel.pipeline.removeHandler(handler)
            }
            logErrorDiagnostics(error: error, operation: "handler \(String(describing: HandlerType.self))")
            if shouldRecycleConnection(for: error) {
                try? await disconnectBody()
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
