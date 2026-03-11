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
    private let connectionID: String
    private let connectionRole: String
    private let connectionContext: String
    private var channel: Channel?
    private var commandTagCounter: Int = 0
    private var capabilities: Set<NIOIMAPCore.Capability> = []
    private var namespaces: NamespaceResponse?
    private var isSessionAuthenticated: Bool = false
    private var idleHandler: IdleHandler?
    private var idleTerminationInProgress: Bool = false
    private let commandQueue = IMAPCommandQueue()
    private let responseBuffer = UntaggedResponseBuffer()

    private let logger: Logging.Logger
    private let duplexLogger: IMAPLogger

    init(
        host: String,
        port: Int,
        group: EventLoopGroup,
        loggerLabel: String,
        outboundLabel: String,
        inboundLabel: String,
        connectionID: String,
        connectionRole: String
    ) {
        self.host = host
        self.port = port
        self.group = group
        self.connectionID = connectionID
        self.connectionRole = connectionRole
        self.connectionContext = "[imap \(host):\(port) role=\(connectionRole) conn=\(connectionID)]"

        var logger = Logging.Logger(label: loggerLabel)
        logger[metadataKey: "imap.host"] = .string(host)
        logger[metadataKey: "imap.port"] = .stringConvertible(port)
        logger[metadataKey: "imap.connection_id"] = .string(connectionID)
        logger[metadataKey: "imap.connection_role"] = .string(connectionRole)
        self.logger = logger

        var outboundLogger = Logging.Logger(label: outboundLabel)
        outboundLogger[metadataKey: "imap.host"] = .string(host)
        outboundLogger[metadataKey: "imap.port"] = .stringConvertible(port)
        outboundLogger[metadataKey: "imap.connection_id"] = .string(connectionID)
        outboundLogger[metadataKey: "imap.connection_role"] = .string(connectionRole)

        var inboundLogger = Logging.Logger(label: inboundLabel)
        inboundLogger[metadataKey: "imap.host"] = .string(host)
        inboundLogger[metadataKey: "imap.port"] = .stringConvertible(port)
        inboundLogger[metadataKey: "imap.connection_id"] = .string(connectionID)
        inboundLogger[metadataKey: "imap.connection_role"] = .string(connectionRole)
        self.duplexLogger = IMAPLogger(
            outboundLogger: outboundLogger,
            inboundLogger: inboundLogger,
            contextPrefix: connectionContext
        )
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

    var namespacesSnapshot: NamespaceResponse? {
        namespaces
    }

    var isAuthenticated: Bool {
        isSessionAuthenticated
    }

    var identifier: String {
        connectionID
    }

    var role: String {
        connectionRole
    }

    func supportsCapability(_ check: (Capability) -> Bool) -> Bool {
        capabilities.contains(where: check)
    }

    func replaceCapabilitiesForTesting(_ capabilities: Set<NIOIMAPCore.Capability>) {
        self.capabilities = capabilities
    }

    func connect() async throws {
        try await commandQueue.run { [self] in
            try await self.connectBody()
        }
    }

    func done(timeoutSeconds: TimeInterval = 15) async throws {
        try await commandQueue.run { [self] in
            try await self.doneBody(timeoutSeconds: timeoutSeconds)
        }
    }

    func disconnect() async throws {
        try await commandQueue.run { [self] in
            try await self.disconnectBody()
        }
    }

    private func connectBody() async throws {
        clearInvalidChannel()
        if channel?.isActive == true {
            logger.debug("\(connectionContext) connect requested while channel is already active")
            return
        }

        // Any buffered state belongs to a previous transport and must not leak.
        responseBuffer.reset()
        idleHandler = nil
        idleTerminationInProgress = false

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
        self.isSessionAuthenticated = false
        self.namespaces = nil

        // Add the persistent untagged response buffer as the LAST handler in the pipeline.
        // Transient command handlers are added BEFORE it (position: .before(responseBuffer)).
        // channelRead flows first→last, so: command handler processes response → calls
        // fireChannelRead → buffer sees it. When no command handler is active, responses
        // flow directly to the buffer which captures them for later draining.
        try await channel.pipeline.addHandler(responseBuffer).get()

        logger.info("\(connectionContext) Connected to IMAP server with 1MB buffer limit for large responses")

        let greetingCapabilities: [Capability] = try await executeHandlerOnly(handlerType: IMAPGreetingHandler.self, timeoutSeconds: 5)
        try await refreshCapabilities(using: greetingCapabilities)
    }

    private func doneBody(timeoutSeconds: TimeInterval = 15) async throws {
        guard let handler = idleHandler else {
            logger.debug("\(connectionContext) No active IDLE session, skipping DONE command")
            return
        }

        if handler.isCompleted {
            logger.warning(
                "\(connectionContext) IDLE already completed before DONE; forcing reconnect due to ambiguous IDLE completion state"
            )
            idleHandler = nil
            responseBuffer.hasActiveHandler = false
            try? await disconnectBody()
            throw IMAPError.connectionFailed(
                "Ambiguous IDLE completion detected before DONE; connection recycled to resynchronize IMAP state"
            )
        }

        guard let channel = self.channel, channel.isActive else {
            let terminationReasons = responseBuffer.consumeBufferedConnectionTerminationReasons()
            if !terminationReasons.isEmpty {
                let reason = terminationReasons.joined(separator: " | ")
                logger.info("\(connectionContext) Skipping DONE because server already closed connection: \(reason)")
                idleHandler = nil
                responseBuffer.hasActiveHandler = false
                return
            }

            logger.warning("\(connectionContext) Cannot send DONE because channel is not active")
            idleHandler = nil
            responseBuffer.hasActiveHandler = false
            throw IMAPError.connectionFailed("Channel is not active")
        }

        guard !idleTerminationInProgress else {
            try await waitForIdleHandlerCompletion(handler, timeoutSeconds: timeoutSeconds)
            return
        }

        idleTerminationInProgress = true

        defer {
            idleTerminationInProgress = false
            idleHandler = nil
            responseBuffer.hasActiveHandler = false
        }

        do {
            try await waitForIdleStartIfNeeded(handler, timeoutSeconds: min(timeoutSeconds, 5))
            _ = try await waitForFutureWithTimeout(
                channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.idleDone)),
                timeoutSeconds: timeoutSeconds
            )
            try await waitForIdleHandlerCompletion(handler, timeoutSeconds: timeoutSeconds)
            duplexLogger.flushInboundBuffer()
        } catch {
            duplexLogger.flushInboundBuffer()

            if error is CancellationError {
                throw error
            }

            if handler.isCompleted {
                logger.info("\(connectionContext) Server closed connection while IDLE termination was in progress")
                return
            }

            logErrorDiagnostics(error: error, operation: "DONE")

            if let imapError = error as? IMAPError, case .timeout = imapError {
                logger.warning("\(connectionContext) Timed out waiting for IDLE termination after DONE")
            } else {
                logger.warning("\(connectionContext) Failed to terminate IDLE after DONE: \(error)")
            }

            try? await disconnectBody()
            throw error
        }
    }

    private func disconnectBody() async throws {
        guard let channel = self.channel else {
            logger.warning("\(connectionContext) Attempted to disconnect when channel was already nil")
            isSessionAuthenticated = false
            responseBuffer.reset()
            idleHandler = nil
            idleTerminationInProgress = false
            return
        }

        do {
            try await channel.close().get()
        } catch {
            logger.debug("\(connectionContext) Channel close during disconnect reported: \(error)")
        }
        self.channel = nil
        self.isSessionAuthenticated = false
        self.namespaces = nil
        self.idleHandler = nil
        self.idleTerminationInProgress = false
        self.responseBuffer.reset()
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
        isSessionAuthenticated = true
        try await refreshCapabilities(using: loginCapabilities)
        await fetchNamespacesIfSupported(useCommandBody: false)
    }

    /// Authenticate using AUTHENTICATE PLAIN (RFC 4616) with optional SASL-IR (RFC 4959).
    ///
    /// When the server advertises `SASL-IR`, the credentials are sent inline with the
    /// AUTHENTICATE command (saving a round trip). Otherwise falls back to the standard
    /// continuation-based exchange.
    func authenticatePlain(username: String, password: String) async throws {
        try await commandQueue.run { [self] in
            try await self.authenticatePlainBody(username: username, password: password)
        }
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

    func noop() async throws -> [IMAPServerEvent] {
        let command = NoopCommand()
        return try await executeCommand(command)
    }

    /// Drain any untagged responses that were buffered between command handlers.
    ///
    /// Returns them converted to `IMAPServerEvent`s. Responses that don't map
    /// to a known event type are logged and skipped.
    func drainBufferedEvents() -> [IMAPServerEvent] {
        let raw = responseBuffer.drainBuffer()
        guard !raw.isEmpty else { return [] }

        let terminationReasons = responseBuffer.consumeBufferedConnectionTerminationReasons()
        if !terminationReasons.isEmpty {
            logger.warning(
                "\(connectionContext) Draining \(terminationReasons.count) buffered connection termination signal(s): \(terminationReasons.joined(separator: " | "))"
            )
        }

        logger.debug("\(connectionContext) Draining \(raw.count) buffered response(s)")
        var events: [IMAPServerEvent] = []

        for response in raw {
            switch response {
            case .untagged(let payload):
                switch payload {
                case .mailboxData(let data):
                    switch data {
                    case .exists(let count):
                        events.append(.exists(Int(count)))
                    case .recent(let count):
                        events.append(.recent(Int(count)))
                    case .flags(let flags):
                        events.append(.flags(flags.map { Flag(nio: $0) }))
                    default:
                        logger.debug("Buffered unhandled mailboxData: \(data)")
                    }
                case .messageData(let data):
                    switch data {
                    case .expunge(let seq):
                        events.append(.expunge(SequenceNumber(seq.rawValue)))
                    default:
                        logger.debug("Buffered unhandled messageData: \(data)")
                    }
                case .conditionalState(let status):
                    switch status {
                    case .ok(let text):
                        if text.code == .alert {
                            events.append(.alert(text.text))
                        }
                    case .bye(let text):
                        events.append(.bye(text.text))
                    default:
                        break
                    }
                case .capabilityData(let caps):
                    events.append(.capability(caps.map { String($0) }))
                default:
                    logger.debug("Buffered unhandled payload: \(payload)")
                }
            case .fetch(let fetch):
                // Collect fetch attributes from buffered fetch sequence
                switch fetch {
                case .start, .startUID, .simpleAttribute, .finish:
                    // Individual fetch parts can't be meaningfully reconstructed here
                    // since we may not have the complete sequence. Log it.
                    logger.debug("Buffered fetch response part: \(fetch)")
                default:
                    logger.debug("Buffered unhandled fetch: \(fetch)")
                }
            case .fatal(let text):
                events.append(.bye(text.text))
            default:
                break
            }
        }

        return events
    }

    // MARK: - Private Helpers

    private func refreshCapabilities(using reportedCapabilities: [Capability]) async throws {
        if !reportedCapabilities.isEmpty {
            self.capabilities = Set(reportedCapabilities)
            return
        }

        try await fetchCapabilities()
    }

    
    func fetchNamespaces() async throws -> NamespaceResponse {
        let response = try await executeCommand(NamespaceCommand())
        namespaces = response
        return response
    }

    private func fetchNamespacesIfSupported(useCommandBody: Bool) async {
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

    private func authenticatePlainBody(username: String, password: String) async throws {
        let mechanism = AuthenticationMechanism("PLAIN")
        let plainCapability = Capability.authenticate(mechanism)

        guard capabilities.contains(plainCapability) else {
            throw IMAPError.unsupportedAuthMechanism("PLAIN not advertised by server")
        }

        try await waitForIdleCompletionIfNeeded()
        try await recycleConnectionIfBufferedTerminationIfNeeded(operation: "PLAIN authenticate")

        clearInvalidChannel()

        if self.channel == nil {
            logger.info("\(connectionContext) Channel is nil, re-establishing connection before authentication")
            try await connectBody()
        }

        guard let channel = self.channel, channel.isActive else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }

        let tag = generateCommandTag()

        let handlerPromise = channel.eventLoop.makePromise(of: [Capability].self)
        let credentialBuffer = makePlainCredentialBuffer(username: username, password: password)
        let (initialResponse, expectsChallenge) = resolveSASLIR(credentials: credentialBuffer)

        let handler = PlainAuthenticationHandler(
            commandTag: tag,
            promise: handlerPromise,
            credentials: credentialBuffer,
            expectsChallenge: expectsChallenge
        )

        var scheduledTask: Scheduled<Void>?

        do {
            try await channel.pipeline.addHandler(handler, position: .before(responseBuffer)).get()
            responseBuffer.hasActiveHandler = true

            let command = TaggedCommand(tag: tag, command: .authenticate(mechanism: mechanism, initialResponse: initialResponse))
            let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(command))

            let authenticationTimeoutSeconds = 10
            let logger = self.logger
            scheduledTask = channel.eventLoop.scheduleTask(in: .seconds(Int64(authenticationTimeoutSeconds))) {
                logger.warning("PLAIN authentication timed out after \(authenticationTimeoutSeconds) seconds")
                handlerPromise.fail(IMAPError.timeout)
            }

            try await channel.writeAndFlush(wrapped)
            let postAuthCapabilities = try await handlerPromise.futureResult.get()

            scheduledTask?.cancel()
            responseBuffer.hasActiveHandler = false
            isSessionAuthenticated = true

            duplexLogger.flushInboundBuffer()
            try await refreshCapabilities(using: postAuthCapabilities)
            await fetchNamespacesIfSupported(useCommandBody: true)
        } catch {
            scheduledTask?.cancel()
            responseBuffer.hasActiveHandler = false

            // Ensure the promise is resolved to prevent NIO "leaking promise" fatal error
            handlerPromise.fail(error)

            duplexLogger.flushInboundBuffer()
            if !handler.isCompleted {
                try? await channel.pipeline.removeHandler(handler)
            }
            logErrorDiagnostics(error: error, operation: "PLAIN authenticate [\(tag)]")
            if shouldRecycleConnection(for: error) {
                try? await disconnectBody()
            }
            throw error
        }
    }

    // MARK: - SASL-IR Helpers

    /// Resolve whether to use SASL-IR (RFC 4959) for the given credentials.
    ///
    /// Returns the `InitialResponse` to embed in the AUTHENTICATE command (nil = use continuation)
    /// and whether the handler should expect a server challenge before sending credentials.
    ///
    /// - Parameters:
    ///   - credentials: The pre-built credential buffer.
    ///   - maxInlineBytes: Maximum payload size for inline SASL-IR. Payloads exceeding this
    ///     fall back to continuation mode even when SASL-IR is supported (prevents issues with
    ///     servers that impose line-length limits). Pass `nil` for no limit.
    /// - Returns: A tuple of `(initialResponse, expectsChallenge)`.
    private func resolveSASLIR(
        credentials: ByteBuffer,
        maxInlineBytes: Int? = nil
    ) -> (initialResponse: InitialResponse?, expectsChallenge: Bool) {
        let supportsSASLIR = capabilities.contains(.saslIR)

        if supportsSASLIR {
            if let limit = maxInlineBytes, credentials.readableBytes > limit {
                logger.info("SASL-IR payload size \(credentials.readableBytes) exceeds inline limit \(limit); switching to continuation mode")
                return (nil, true)
            }
            return (InitialResponse(credentials), false)
        }

        return (nil, true)
    }

    /// Build the RFC 4616 PLAIN credential buffer: \0username\0password
    private func makePlainCredentialBuffer(username: String, password: String) -> ByteBuffer {
        // PLAIN format: [authzid] NUL authcid NUL passwd
        // authzid is empty (same as authcid)
        var buffer = ByteBufferAllocator().buffer(capacity: username.utf8.count + password.utf8.count + 2)
        buffer.writeInteger(UInt8(0x00))  // empty authzid
        buffer.writeString(username)
        buffer.writeInteger(UInt8(0x00))
        buffer.writeString(password)
        return buffer
    }

    private func authenticateXOAUTH2Body(email: String, accessToken: String) async throws {
        let mechanism = AuthenticationMechanism("XOAUTH2")
        let xoauthCapability = Capability.authenticate(mechanism)

        guard capabilities.contains(xoauthCapability) else {
            throw IMAPError.unsupportedAuthMechanism("XOAUTH2 not advertised by server")
        }

        try await waitForIdleCompletionIfNeeded()
        try await recycleConnectionIfBufferedTerminationIfNeeded(operation: "XOAUTH2 authenticate")

        clearInvalidChannel()

        if self.channel == nil {
            logger.info("\(connectionContext) Channel is nil, re-establishing connection before authentication")
            try await connectBody()
        }

        guard let channel = self.channel, channel.isActive else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }

        let tag = generateCommandTag()

        let handlerPromise = channel.eventLoop.makePromise(of: [Capability].self)
        let credentialBuffer = makeXOAUTH2InitialResponseBuffer(email: email, accessToken: accessToken)
        let (initialResponse, expectsChallenge) = resolveSASLIR(credentials: credentialBuffer, maxInlineBytes: 1024)

        let handler = XOAUTH2AuthenticationHandler(
            commandTag: tag,
            promise: handlerPromise,
            credentials: credentialBuffer,
            expectsChallenge: expectsChallenge,
            logger: logger
        )

        var scheduledTask: Scheduled<Void>?

        do {
            try await channel.pipeline.addHandler(handler, position: .before(responseBuffer)).get()
            responseBuffer.hasActiveHandler = true

            let command = TaggedCommand(tag: tag, command: .authenticate(mechanism: mechanism, initialResponse: initialResponse))
            let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(command))

            let authenticationTimeoutSeconds = 10
            let logger = self.logger
            // Schedule on the channel event loop to avoid cross-loop promise completion.
            scheduledTask = channel.eventLoop.scheduleTask(in: .seconds(Int64(authenticationTimeoutSeconds))) {
                logger.warning("XOAUTH2 authentication timed out after \(authenticationTimeoutSeconds) seconds")
                handlerPromise.fail(IMAPError.timeout)
            }

            try await channel.writeAndFlush(wrapped).get()
            let refreshedCapabilities = try await handlerPromise.futureResult.get()

            scheduledTask?.cancel()
            responseBuffer.hasActiveHandler = false
            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            duplexLogger.flushInboundBuffer()

            isSessionAuthenticated = true
            if !refreshedCapabilities.isEmpty {
                self.capabilities = Set(refreshedCapabilities)
            } else {
                // AUTHENTICATE often returns an OK without CAPABILITY data.
                // Avoid issuing a follow-up CAPABILITY command here because we're already
                // inside commandQueue.run, and a nested executeCommand would deadlock.
                logger.debug("XOAUTH2 completed without capability data; retaining existing capability snapshot")
            }

            await fetchNamespacesIfSupported(useCommandBody: true)
        } catch {
            scheduledTask?.cancel()
            responseBuffer.hasActiveHandler = false

            let earlyFailure = !handler.isCompleted
            if earlyFailure {
                logger.debug("XOAUTH2_EARLY_SEND_FAILURE auth write failed before handler completion")
            }

            // Ensure the command promise is always resolved on early auth failures
            // (for example write failure on a closed channel before handler callbacks fire).
            handlerPromise.fail(error)
            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            duplexLogger.flushInboundBuffer()

            logErrorDiagnostics(error: error, operation: "XOAUTH2 authenticate")

            if earlyFailure {
                try? await channel.pipeline.removeHandler(handler)
            }

            if shouldRecycleConnection(for: error) {
                try? await disconnectBody()
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

    private func handleConnectionTerminationInResponses(_ untaggedResponses: [Response]) async {
        for response in untaggedResponses {
            if case .untagged(let payload) = response,
               case .conditionalState(let status) = payload,
               case .bye = status {
                try? await self.disconnectBody()
                break
            }
            if case .fatal = response {
                try? await self.disconnectBody()
                break
            }
        }
    }

    private func waitForIdleCompletionIfNeeded(timeoutSeconds: TimeInterval = 15) async throws {
        guard let handler = idleHandler else { return }
        do {
            try await waitForIdleHandlerCompletion(handler, timeoutSeconds: timeoutSeconds)
        } catch {
            logger.warning("\(connectionContext) IDLE handler did not complete in time; resetting connection before continuing")
            idleHandler = nil
            responseBuffer.hasActiveHandler = false
            try? await disconnectBody()
            throw error
        }
    }

    private func waitForIdleStartIfNeeded(_ handler: IdleHandler, timeoutSeconds: TimeInterval) async throws {
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

    private func waitForIdleHandlerCompletion(_ handler: IdleHandler, timeoutSeconds: TimeInterval) async throws {
        _ = try await waitForFutureWithTimeout(handler.promise.futureResult, timeoutSeconds: timeoutSeconds)
    }

    private func waitForFutureWithTimeout<T: Sendable>(
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

    private func recycleConnectionIfBufferedTerminationIfNeeded(operation: String) async throws {
        guard responseBuffer.hasBufferedConnectionTermination else { return }
        let reasons = responseBuffer.consumeBufferedConnectionTerminationReasons()
        let reasonSummary = reasons.isEmpty ? "<unknown>" : reasons.joined(separator: " | ")
        logger.warning("\(connectionContext) Buffered BYE/fatal detected before \(operation). Recycling connection. reasons=\(reasonSummary)")
        try await disconnectBody()
    }

    private func shouldRecycleConnection(for error: Error) -> Bool {
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

        let description = String(describing: error).lowercased()
        return description.contains("decodererror")
            || description.contains("parsererror")
            || description.contains("channel is not active")
            || description.contains("connection reset by peer")
            || description.contains("broken pipe")
            || description.contains("eof")
            || description.contains("invalid state")
    }

    private func logErrorDiagnostics(error: Error, operation: String) {
        let active = channel?.isActive ?? false
        let diagnostics = """
        \(connectionContext) \(operation) failed: \(error); \
        channelActive=\(active) authenticated=\(isSessionAuthenticated) \
        idleHandlerActive=\(idleHandler != nil) idleTerminationInProgress=\(idleTerminationInProgress) \
        bufferedResponses=\(responseBuffer.bufferedCount) bufferedTermination=\(responseBuffer.hasBufferedConnectionTermination)
        """
        logger.error("\(diagnostics)")
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
        try await recycleConnectionIfBufferedTerminationIfNeeded(operation: String(describing: CommandType.self))

        clearInvalidChannel()

        if self.channel == nil {
            logger.info("\(connectionContext) Channel is nil, re-establishing connection before sending command")
            try await connectBody()
        }

        guard let channel = self.channel, channel.isActive else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }

        let resultPromise = channel.eventLoop.makePromise(of: CommandType.ResultType.self)
        let tag = generateCommandTag()
        let handler = CommandType.HandlerType.init(commandTag: tag, promise: resultPromise)
        let timeoutSeconds = command.timeoutSeconds

        let logger = self.logger
        let scheduledTask = channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            logger.warning("Command timed out after \(timeoutSeconds) seconds")
            resultPromise.fail(IMAPError.timeout)
        }

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

    private func executeHandlerOnly<T: Sendable, HandlerType: IMAPCommandHandler>(
        handlerType: HandlerType.Type,
        timeoutSeconds: Int = 5
    ) async throws -> T where HandlerType.ResultType == T {
        try await recycleConnectionIfBufferedTerminationIfNeeded(operation: String(describing: HandlerType.self))
        clearInvalidChannel()

        if self.channel == nil {
            logger.info("\(connectionContext) Channel is nil, re-establishing connection before executing handler")
            try await connectBody()
        }

        guard let channel = self.channel, channel.isActive else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }

        let resultPromise = channel.eventLoop.makePromise(of: T.self)
        let handler = HandlerType.init(commandTag: "", promise: resultPromise)

        let logger = self.logger
        let scheduledTask = channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            logger.warning("Handler execution timed out after \(timeoutSeconds) seconds")
            resultPromise.fail(IMAPError.timeout)
        }

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

    private func clearInvalidChannel() {
        if let channel = self.channel, !channel.isActive {
            logger.info("\(connectionContext) Channel is no longer active, clearing channel reference")
            self.channel = nil
            self.isSessionAuthenticated = false
            self.idleHandler = nil
            self.idleTerminationInProgress = false
            self.responseBuffer.reset()
        }
    }

    private func generateCommandTag() -> String {
        let tagPrefix = "A"
        commandTagCounter += 1
        return "\(tagPrefix)\(String(format: "%03d", commandTagCounter))"
    }
}
