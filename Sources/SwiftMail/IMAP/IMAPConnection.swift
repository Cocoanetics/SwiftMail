import Foundation
import Logging
import NIO
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIOSSL

/// Internal connection wrapper used by IMAPServer to manage per-connection state.
final class IMAPConnection {
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
    let group: EventLoopGroup
    let connectionID: String
    let connectionRole: String
    let connectionContext: String
    var channel: Channel?
    var commandTagCounter: Int = 0
    var capabilities: Set<NIOIMAPCore.Capability> = []
    var namespaces: NamespaceResponse?
    var isSessionAuthenticated: Bool = false
    var idleHandler: IdleHandler?
    var idleTerminationInProgress: Bool = false
    let commandQueue = IMAPCommandQueue()
    let responseBuffer = UntaggedResponseBuffer()
    var startTLSUpgradeOverrideForTesting: (() async throws -> Void)?

    let logger: Logging.Logger
    let duplexLogger: IMAPLogger

    init(
        host: String,
        port: Int,
        transportSecurity: MailTransportSecurity = .automatic,
        certificateVerificationPolicy: MailCertificateVerificationPolicy = .fullVerification,
        group: EventLoopGroup,
        loggerLabel: String,
        outboundLabel: String,
        inboundLabel: String,
        connectionID: String,
        connectionRole: String
    ) {
        self.host = host
        self.port = port
        self.transportSecurity = transportSecurity
        self.certificateVerificationPolicy = certificateVerificationPolicy
        self.group = group
        self.connectionID = connectionID
        self.connectionRole = connectionRole
        connectionContext = "[imap \(host):\(port) role=\(connectionRole) conn=\(connectionID)]"

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
        duplexLogger = IMAPLogger(
            outboundLogger: outboundLogger,
            inboundLogger: inboundLogger,
            contextPrefix: connectionContext
        )
    }

    convenience init(
        host: String,
        port: Int,
        useTLS: Bool?,
        group: EventLoopGroup,
        loggerLabel: String,
        outboundLabel: String,
        inboundLabel: String,
        connectionID: String,
        connectionRole: String
    ) {
        self.init(
            host: host,
            port: port,
            transportSecurity: Self.resolveLegacyTransportSecurity(port: port, useTLS: useTLS),
            certificateVerificationPolicy: .fullVerification,
            group: group,
            loggerLabel: loggerLabel,
            outboundLabel: outboundLabel,
            inboundLabel: inboundLabel,
            connectionID: connectionID,
            connectionRole: connectionRole
        )
    }

    private static func resolveLegacyTransportSecurity(port: Int, useTLS: Bool?) -> MailTransportSecurity {
        guard let useTLS else {
            return .automatic
        }

        if useTLS {
            return port == 143 ? .startTLS : .implicitTLS
        }

        return .plainText
    }

    static func resolveTLSTransportMode(
        port: Int,
        transportSecurity: MailTransportSecurity
    ) throws -> TLSTransportMode {
        switch transportSecurity {
            case .automatic:
                switch port {
                    case 993:
                        return .implicitTLS
                    case 143:
                        return .startTLSIfAvailable
                    default:
                        throw IMAPError.invalidArgument(
                            "Port \(port) requires explicit transportSecurity because TLS mode cannot be inferred"
                        )
                }
            case .implicitTLS:
                return .implicitTLS
            case .startTLS:
                return .startTLSRequired
            case .plainText:
                return .plainText
        }
    }

    static func requiresSTARTTLSUpgrade(
        tlsTransportMode: TLSTransportMode,
        capabilities: [Capability]
    ) -> Bool {
        switch tlsTransportMode {
            case .startTLSIfAvailable, .startTLSRequired:
                capabilities.contains(.startTLS)
            case .implicitTLS, .plainText:
                false
        }
    }

    static func requiresMissingSTARTTLSError(
        tlsTransportMode: TLSTransportMode,
        capabilities: [Capability]
    ) -> Bool {
        tlsTransportMode == .startTLSRequired && !capabilities.contains(.startTLS)
    }

    var isConnected: Bool {
        guard let channel else {
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

    func replaceChannelForTesting(_ channel: Channel?) {
        self.channel = channel
    }

    func replaceStartTLSUpgradeForTesting(_ upgrade: (() async throws -> Void)?) {
        startTLSUpgradeOverrideForTesting = upgrade
    }

    func connect() async throws {
        try await commandQueue.run { [self] in
            try await connectBody()
        }
    }

    func done(timeoutSeconds: TimeInterval = 15) async throws {
        try await commandQueue.run { [self] in
            try await doneBody(timeoutSeconds: timeoutSeconds)
        }
    }

    func disconnect() async throws {
        try await commandQueue.run { [self] in
            try await disconnectBody()
        }
    }
}
