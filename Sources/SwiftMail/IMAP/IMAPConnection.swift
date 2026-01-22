import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOSSL

/// Internal connection wrapper used by IMAPServer to manage per-connection state.
final class IMAPConnection {
    private let host: String
    private let port: Int
    private let group: EventLoopGroup
    private var channel: Channel?
    private var commandTagCounter: Int = 0
    private var capabilities: Set<NIOIMAPCore.Capability> = []
    private var idleHandler: IdleHandler?
    private var idleTerminationInProgress: Bool = false
    private let commandQueue = IMAPCommandQueue()

    private let logger: Logging.Logger
    private let duplexLogger: IMAPLogger

    init(host: String, port: Int, group: EventLoopGroup, loggerLabel: String, outboundLabel: String, inboundLabel: String) {
        self.host = host
        self.port = port
        self.group = group

        self.logger = Logging.Logger(label: loggerLabel)
        let outboundLogger = Logging.Logger(label: outboundLabel)
        let inboundLogger = Logging.Logger(label: inboundLabel)
        self.duplexLogger = IMAPLogger(outboundLogger: outboundLogger, inboundLogger: inboundLogger)
    }

    var isConnected: Bool {
        guard let channel = self.channel else {
            return false
        }
        return channel.isActive
    }

    var capabilitiesSnapshot: Set<NIOIMAPCore.Capability> {
        capabilities
    }

    func supportsCapability(_ check: (Capability) -> Bool) -> Bool {
        capabilities.contains(where: check)
    }

    func connect() async throws {
        let sslContext = try NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
        let host = self.host

        let duplexLogger = self.duplexLogger
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                let sslHandler = try! NIOSSLClientHandler(context: sslContext, serverHostname: host)

                let parserOptions = ResponseParser.Options(
                    bufferLimit: 1024 * 1024,
                    messageAttributeLimit: .max,
                    bodySizeLimit: .max,
                    literalSizeLimit: IMAPDefaults.literalSizeLimit
                )

                try! channel.pipeline.syncOperations.addHandlers([
                    sslHandler,
                    IMAPClientHandler(parserOptions: parserOptions),
                    duplexLogger
                ])

                return channel.eventLoop.makeSucceededFuture(())
            }

        let channel = try await bootstrap.connect(host: host, port: port).get()
        self.channel = channel

        logger.info("Connected to IMAP server with 1MB buffer limit for large responses")

        let greetingCapabilities: [Capability] = try await executeHandlerOnly(handlerType: IMAPGreetingHandler.self, timeoutSeconds: 5)
        try await refreshCapabilities(using: greetingCapabilities)
    }

    @discardableResult func fetchCapabilities() async throws -> [Capability] {
        let command = CapabilityCommand()
        let serverCapabilities = try await executeCommand(command)
        self.capabilities = Set(serverCapabilities)
        return serverCapabilities
    }

    func login(username: String, password: String) async throws {
        let command = LoginCommand(username: username, password: password)
        let loginCapabilities = try await executeCommand(command)
        try await refreshCapabilities(using: loginCapabilities)
    }

    func authenticateXOAUTH2(email: String, accessToken: String) async throws {
        try await commandQueue.run { [self] in
            try await self.authenticateXOAUTH2Body(email: email, accessToken: accessToken)
        }
    }

    func id(_ identification: Identification = Identification()) async throws -> Identification {
        guard capabilities.contains(.id) else {
            throw IMAPError.commandNotSupported("ID command not supported by server")
        }

        let command = IDCommand(identification: identification)
        return try await executeCommand(command)
    }

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

    func done() async throws {
        guard let handler = idleHandler else {
            logger.debug("No active IDLE session, skipping DONE command")
            return
        }

        guard let channel = self.channel else { return }

        guard !idleTerminationInProgress else {
            try await handler.promise.futureResult.get()
            return
        }

        idleTerminationInProgress = true

        defer {
            idleTerminationInProgress = false
            idleHandler = nil
        }

        do {
            try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.idleDone)).get()
        } catch {
            // Ignore write errors during DONE.
        }

        try await handler.promise.futureResult.get()
    }

    func noop() async throws -> [IMAPServerEvent] {
        let command = NoopCommand()
        return try await executeCommand(command)
    }

    func disconnect() async throws {
        guard let channel = self.channel else {
            logger.warning("Attempted to disconnect when channel was already nil")
            return
        }

        channel.close(promise: nil)
        self.channel = nil
    }

    // MARK: - Private Helpers

    private func refreshCapabilities(using reportedCapabilities: [Capability]) async throws {
        if !reportedCapabilities.isEmpty {
            self.capabilities = Set(reportedCapabilities)
        } else {
            try await fetchCapabilities()
        }
    }

    private func authenticateXOAUTH2Body(email: String, accessToken: String) async throws {
        let mechanism = AuthenticationMechanism("XOAUTH2")
        let xoauthCapability = Capability.authenticate(mechanism)

        guard capabilities.contains(xoauthCapability) else {
            throw IMAPError.unsupportedAuthMechanism("XOAUTH2 not advertised by server")
        }

        try await waitForIdleCompletionIfNeeded()

        clearInvalidChannel()

        if self.channel == nil {
            logger.info("Channel is nil, re-establishing connection before authentication")
            try await connect()
        }

        guard let channel = self.channel else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }

        let expectsChallenge = !capabilities.contains(.saslIR)
        let tag = generateCommandTag()

        let handlerPromise = channel.eventLoop.makePromise(of: [Capability].self)
        let credentialBuffer = makeXOAUTH2InitialResponseBuffer(email: email, accessToken: accessToken)
        let handler = XOAUTH2AuthenticationHandler(
            commandTag: tag,
            promise: handlerPromise,
            credentials: credentialBuffer,
            expectsChallenge: expectsChallenge,
            logger: logger
        )

        try await channel.pipeline.addHandler(handler).get()

        let initialResponse = expectsChallenge ? nil : InitialResponse(credentialBuffer)

        let command = TaggedCommand(tag: tag, command: .authenticate(mechanism: mechanism, initialResponse: initialResponse))
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(command))

        let authenticationTimeoutSeconds = 10
        let logger = self.logger
        let scheduledTask = group.next().scheduleTask(in: .seconds(Int64(authenticationTimeoutSeconds))) {
            logger.warning("XOAUTH2 authentication timed out after \(authenticationTimeoutSeconds) seconds")
            handlerPromise.fail(IMAPError.timeout)
        }

        do {
            try await channel.writeAndFlush(wrapped).get()
            let refreshedCapabilities = try await handlerPromise.futureResult.get()

            scheduledTask.cancel()
            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            duplexLogger.flushInboundBuffer()

            try await refreshCapabilities(using: refreshedCapabilities)
        } catch {
            scheduledTask.cancel()
            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            duplexLogger.flushInboundBuffer()

            if !handler.isCompleted {
                try? await channel.pipeline.removeHandler(handler)
            }

            throw error
        }
    }

    private func startIdleSession(continuation: AsyncStream<IMAPServerEvent>.Continuation) async throws {
        if !capabilities.contains(.idle) {
            throw IMAPError.commandNotSupported("IDLE command not supported by server")
        }

        guard idleHandler == nil else {
            throw IMAPError.commandFailed("IDLE session already active")
        }

        idleTerminationInProgress = false

        guard let channel = self.channel else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }

        let promise = channel.eventLoop.makePromise(of: Void.self)
        let tag = generateCommandTag()
        let handler = IdleHandler(commandTag: tag, promise: promise, continuation: continuation)
        idleHandler = handler

        try await channel.pipeline.addHandler(handler).get()
        let command = IdleCommand()
        let tagged = command.toTaggedCommand(tag: tag)
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped).get()
    }

    private func handleConnectionTerminationInResponses(_ untaggedResponses: [Response]) async {
        for response in untaggedResponses {
            if case .untagged(let payload) = response,
               case .conditionalState(let status) = payload,
               case .bye = status {
                try? await self.disconnect()
                break
            }
            if case .fatal = response {
                try? await self.disconnect()
                break
            }
        }
    }

    private func waitForIdleCompletionIfNeeded() async throws {
        guard let handler = idleHandler else { return }
        try await handler.promise.futureResult.get()
    }

    private func makeXOAUTH2InitialResponseBuffer(email: String, accessToken: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: email.utf8.count + accessToken.utf8.count + 32)
        buffer.writeString("user=")
        buffer.writeString(email)
        buffer.writeInteger(UInt8(0x01))
        buffer.writeString("auth=Bearer ")
        buffer.writeString(accessToken)
        buffer.writeInteger(UInt8(0x01))
        buffer.writeInteger(UInt8(0x01))
        return buffer
    }

    func executeCommand<CommandType: IMAPCommand>(_ command: CommandType) async throws -> CommandType.ResultType {
        try await commandQueue.run { [self] in
            try await self.executeCommandBody(command)
        }
    }

    private func executeCommandBody<CommandType: IMAPCommand>(_ command: CommandType) async throws -> CommandType.ResultType {
        try command.validate()
        try await waitForIdleCompletionIfNeeded()

        clearInvalidChannel()

        if self.channel == nil {
            logger.info("Channel is nil, re-establishing connection before sending command")
            try await connect()
        }

        guard let channel = self.channel else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }

        let resultPromise = channel.eventLoop.makePromise(of: CommandType.ResultType.self)
        let tag = generateCommandTag()
        let handler = CommandType.HandlerType.init(commandTag: tag, promise: resultPromise)
        let timeoutSeconds = command.timeoutSeconds

        let logger = self.logger
        let scheduledTask = group.next().scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            logger.warning("Command timed out after \(timeoutSeconds) seconds")
            resultPromise.fail(IMAPError.timeout)
        }

        do {
            try await channel.pipeline.addHandler(handler).get()
            try await command.send(on: channel, tag: tag)
            let result = try await resultPromise.futureResult.get()

            scheduledTask.cancel()

            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            duplexLogger.flushInboundBuffer()

            return result
        } catch {
            scheduledTask.cancel()
            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            duplexLogger.flushInboundBuffer()

            resultPromise.fail(error)
            throw error
        }
    }

    private func executeHandlerOnly<T: Sendable, HandlerType: IMAPCommandHandler>(
        handlerType: HandlerType.Type,
        timeoutSeconds: Int = 5
    ) async throws -> T where HandlerType.ResultType == T {
        clearInvalidChannel()

        if self.channel == nil {
            logger.info("Channel is nil, re-establishing connection before executing handler")
            try await connect()
        }

        guard let channel = self.channel else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }

        let resultPromise = channel.eventLoop.makePromise(of: T.self)
        let handler = HandlerType.init(commandTag: "", promise: resultPromise)

        let logger = self.logger
        let scheduledTask = group.next().scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            logger.warning("Handler execution timed out after \(timeoutSeconds) seconds")
            resultPromise.fail(IMAPError.timeout)
        }

        do {
            try await channel.pipeline.addHandler(handler).get()
            let result = try await resultPromise.futureResult.get()

            scheduledTask.cancel()

            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            duplexLogger.flushInboundBuffer()

            return result
        } catch {
            scheduledTask.cancel()
            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            duplexLogger.flushInboundBuffer()

            resultPromise.fail(error)
            throw error
        }
    }

    private func clearInvalidChannel() {
        if let channel = self.channel, !channel.isActive {
            logger.info("Channel is no longer active, clearing channel reference")
            self.channel = nil
        }
    }

    private func generateCommandTag() -> String {
        let tagPrefix = "A"
        commandTagCounter += 1
        return "\(tagPrefix)\(String(format: "%03d", commandTagCounter))"
    }
}
