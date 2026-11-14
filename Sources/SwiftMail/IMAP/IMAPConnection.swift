import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOSSL

// Session state uses the lifetime gate; pipeline work stays on its event loop
// and configuration/command preparation is serialized by commandQueue.
/// Internal connection wrapper used by IMAPServer to manage per-connection state.
final class IMAPConnection: @unchecked Sendable {
    enum TLSTransportMode: Equatable {
        case implicitTLS
        case plainText
        case startTLSIfAvailable
        case startTLSRequired
    }

    let host: String
    let port: Int
    let transportSecurity: MailTransportSecurity
    let certificateVerificationPolicy: MailCertificateVerificationPolicy
    let minimumTLSVersion: MailTLSMinimumVersion
    let responseBufferLimit: Int
    let parserLimits: IMAPParserLimits
    let group: EventLoopGroup
    let connectionID: String
    let connectionRole: String
    let connectionContext: String
    // All session snapshots and transport publication use the lifetime gate.
    var transport: TransportContext?
    var bootstrapAttempts: [UUID: BootstrapAttempt] = [:]
    var closingTransports: [UUID: TransportContext] = [:]
    var stagingBuffer = UntaggedResponseBuffer()
    var stagingCapabilities: Set<NIOIMAPCore.Capability> = []
    var channel: Channel? { lifetime.gate.withLock { transport?.channel } }
    var commandTagCounter: Int = 0
    var capabilities: Set<NIOIMAPCore.Capability> {
        get { lifetime.gate.withLock { transport?.capabilities ?? stagingCapabilities } }
        set { lifetime.gate.withLock {
            if let transport { transport.capabilities = newValue } else { stagingCapabilities = newValue }
        } }
    }
    var namespaces: NamespaceResponse? {
        get { lifetime.gate.withLock { transport?.namespaces } }
        set { lifetime.gate.withLock { transport?.namespaces = newValue } }
    }
    var isSessionAuthenticated: Bool {
        get { lifetime.gate.withLock { transport?.authenticated ?? false } }
        set { lifetime.gate.withLock { transport?.authenticated = newValue } }
    }
    var idleHandler: IdleHandler? {
        get { lifetime.gate.withLock { transport?.idleHandler } }
        set { lifetime.gate.withLock { transport?.idleHandler = newValue } }
    }
    var idleTerminationInProgress: Bool {
        get { lifetime.gate.withLock { transport?.idleTerminationInProgress ?? false } }
        set { lifetime.gate.withLock { transport?.idleTerminationInProgress = newValue } }
    }
    let lifetime: IMAPConnectionLifetime
    let commandQueue: IMAPCommandQueue
    var responseBuffer: UntaggedResponseBuffer {
        lifetime.gate.withLock { transport?.responseBuffer ?? stagingBuffer }
    }
    var bootstrapOverrideForTesting: ((@escaping (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel>)?
    var lifecycleCheckpointForTesting: ((String) async -> Void)?
    var beforeTransportCloseForTesting: ((TransportContext) async -> Void)?
    var operationOwnerFinishedForTesting: (() -> Void)?
    var channelInitializationForTesting: ((Channel) throws -> Void)?
    var startTLSUpgradeOverrideForTesting: (() async throws -> Void)?
    var capabilityRefreshOverrideForTesting: (() async throws -> Void)?
    var authenticationFollowUpOverrideForTesting: (() async throws -> Void)?
    var connectOverrideForTesting: (() async throws -> Void)?
    var handlerPromiseCreatedForTesting: (() -> Void)?
    /// Re-authenticates this connection inside the command queue after the command path
    /// or an IDLE start had to reopen the transport for a session that was authenticated.
    /// Installed by `IMAPServer` on every connection it authenticates; nil until then.
    var reauthenticateAfterReconnect: (@Sendable (IMAPConnection) async throws -> Void)?
    /// Set when an authenticated session's channel is lost (peer reset, buffered BYE,
    /// timeout recycle) rather than ended on purpose. Cleared by the next successful
    /// authentication and by an explicit `disconnect()`.
    var sessionWasLost = false
    var lostAuthenticatedSession: Bool {
        get { lifetime.gate.withLock { sessionWasLost } }
        set { lifetime.gate.withLock { sessionWasLost = newValue } }
    }
    /// True while LOGIN, AUTHENTICATE PLAIN, or AUTHENTICATE XOAUTH2 runs, so the
    /// capability and namespace refreshes inside it cannot recursively authenticate.
    /// The outer authentication flow detects a replaced transport and retries itself.
    var authenticatingGeneration: ConnectionGeneration?
    var authenticationInProgress: Bool {
        get { lifetime.gate.withLock { authenticatingGeneration != nil } }
        set {
            let generation = lifetime.currentGeneration
            lifetime.gate.withLock { authenticatingGeneration = newValue ? generation : nil }
        }
    }
    /// Whether a command that finds its channel gone reopens the transport (and
    /// re-authenticates) inside itself. When false it throws and opens nothing.
    /// Set by `IMAPServer.setReconnectsInsideCommands(_:)`.
    var reconnectsInsideCommands = true

    let logger: Logging.Logger
    let makeDuplexLogger: () -> IMAPLogger
    lazy var stagingLogger = makeDuplexLogger()
    var duplexLogger: IMAPLogger {
        lifetime.gate.withLock { transport?.duplexLogger ?? stagingLogger }
    }

    /// - Note: `minimumTLSVersion` and `parserLimits` deliberately have **no defaults.**
    ///   They used to, and `makeIdleConnection`/`makeNamedConnection` simply left them out — so
    ///   a server configured with a TLS 1.3 floor and 64 MiB parser limits spawned IDLE and named
    ///   connections with a TLS 1.2 floor and *unbounded* limits, while `IMAPServer`'s
    ///   documentation claimed the policy governed every transport. A default turns "forgot to
    ///   pass the security policy" into "chose the lax one", and neither the compiler nor a
    ///   reviewer can see the difference. Without defaults, omitting one is a build error.
    init(
        host: String,
        port: Int,
        transportSecurity: MailTransportSecurity = .automatic,
        certificateVerificationPolicy: MailCertificateVerificationPolicy = .fullVerification,
        minimumTLSVersion: MailTLSMinimumVersion,
        group: EventLoopGroup,
        loggerLabel: String,
        outboundLabel: String,
        inboundLabel: String,
        connectionID: String,
        connectionRole: String,
        responseBufferLimit: Int = IMAPServer.defaultResponseBufferLimit,
        parserLimits: IMAPParserLimits
    ) {
        let lifetime = IMAPConnectionLifetime()
        self.lifetime = lifetime
        self.commandQueue = IMAPCommandQueue(lifetime: lifetime)
        self.host = host
        self.port = port
        self.transportSecurity = transportSecurity
        self.certificateVerificationPolicy = certificateVerificationPolicy
        self.minimumTLSVersion = minimumTLSVersion
        self.responseBufferLimit = responseBufferLimit
        self.parserLimits = parserLimits
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
        let contextPrefix = self.connectionContext
        self.makeDuplexLogger = { IMAPLogger(
            outboundLogger: outboundLogger,
            inboundLogger: inboundLogger,
            contextPrefix: contextPrefix
        ) }
    }

    /// Legacy convenience initializer taking `useTLS` instead of a `MailTransportSecurity`.
    ///
    /// Security policy is explicit here for the same reason the designated initializer has no
    /// defaults: this call site was invisible to a grep for `IMAPConnection(` and only surfaced
    /// once the compiler demanded the arguments.
    convenience init(
        host: String,
        port: Int,
        useTLS: Bool?,
        group: EventLoopGroup,
        loggerLabel: String,
        outboundLabel: String,
        inboundLabel: String,
        connectionID: String,
        connectionRole: String,
        responseBufferLimit: Int = IMAPServer.defaultResponseBufferLimit,
        minimumTLSVersion: MailTLSMinimumVersion = .tlsv12,
        parserLimits: IMAPParserLimits = .default
    ) {
        self.init(
            host: host,
            port: port,
            transportSecurity: Self.resolveLegacyTransportSecurity(port: port, useTLS: useTLS),
            certificateVerificationPolicy: .fullVerification,
            minimumTLSVersion: minimumTLSVersion,
            group: group,
            loggerLabel: loggerLabel,
            outboundLabel: outboundLabel,
            inboundLabel: inboundLabel,
            connectionID: connectionID,
            connectionRole: connectionRole,
            responseBufferLimit: responseBufferLimit,
            parserLimits: parserLimits
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

    var certificateVerificationPolicyForTesting: MailCertificateVerificationPolicy {
        certificateVerificationPolicy
    }

    var responseBufferLimitForTesting: Int {
        responseBufferLimit
    }

    var namespacesSnapshot: NamespaceResponse? {
        namespaces
    }

    /// An authenticated session needs a live channel. A transport the peer reset leaves
    /// `isSessionAuthenticated` set until the next command notices the dead channel, and a
    /// caller that trusted the flag alone then sent an authenticated-state command on the
    /// fresh transport `executeCommandBody` reopens (Gmail answers `BAD Unknown command`).
    var isAuthenticated: Bool {
        lifetime.gate.withLock { transport?.authenticated == true && transport?.channel.isActive == true }
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

    func replaceChannelForTesting(_ channel: Channel?) {
        let generation = lifetime.currentGeneration
        lifetime.gate.withLock {
            guard let channel else { transport = nil; return }
            let context = TransportContext(generation: generation, channel: channel,
                                           responseBuffer: stagingBuffer, duplexLogger: stagingLogger)
            context.capabilities = transport?.capabilities ?? stagingCapabilities
            transport = context
        }
    }

    func replaceStartTLSUpgradeForTesting(_ upgrade: (() async throws -> Void)?) {
        self.startTLSUpgradeOverrideForTesting = upgrade
    }

    func replaceCapabilityRefreshForTesting(_ refresh: (() async throws -> Void)?) {
        self.capabilityRefreshOverrideForTesting = refresh
    }

    func replaceConnectForTesting(_ connect: (() async throws -> Void)?) {
        self.connectOverrideForTesting = connect
    }

    func connect() async throws {
        // Recovery calls connectBody directly and can never rearm an abort.
        if operationToken == nil { lifetime.rearm() }
        try await withOperation { [self] in
            try await self.connectBody()
        }
    }

    func done(timeoutSeconds: TimeInterval = 15) async throws {
        try await withOperation { [self] in
            try await self.doneBody(timeoutSeconds: timeoutSeconds)
        }
    }

    func disconnect() async throws {
        try await withOperation(forCleanup: true) { [self] in
            try await self.disconnectBody()
            // Ending the session on purpose is not losing it.
            try lifetime.gate.withLock {
                if let token = operationToken { try lifetime.validateLocked(token) }
                sessionWasLost = false
            }
        }
    }
}
