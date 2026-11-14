import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOSSL

extension IMAPConnection {
    static func resolveLegacyTransportSecurity(port: Int, useTLS: Bool?) -> MailTransportSecurity {
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
                return capabilities.contains(.startTLS)
            case .implicitTLS, .plainText:
                return false
        }
    }

    static func requiresMissingSTARTTLSError(
        tlsTransportMode: TLSTransportMode,
        capabilities: [Capability]
    ) -> Bool {
        tlsTransportMode == .startTLSRequired && !capabilities.contains(.startTLS)
    }

    /// - Note: `minimumTLSVersion` has **no default on purpose.** It used to default to
    ///   `.tlsv12`, and the implicit-TLS call site simply omitted it — so a caller asking for
    ///   `.tlsv13` on port 993 silently got a TLS 1.2 floor. A default here makes forgetting the
    ///   argument indistinguishable from choosing a value, and the compiler cannot help. Every
    ///   call site now has to say what it means.
    static func makeTLSHandler(
        for channel: Channel,
        host: String,
        certificateVerificationPolicy: MailCertificateVerificationPolicy,
        minimumTLSVersion: MailTLSMinimumVersion
    ) throws -> NIOSSLClientHandler {
        let configuration = MailTLSConfiguration.makeClientConfiguration(
            certificateVerificationPolicy: certificateVerificationPolicy,
            minimumTLSVersion: minimumTLSVersion
        )
        let context = try NIOSSLContext(configuration: configuration)
        let serverHostname = MailTLSConfiguration.serverHostnameForTLSHandler(host: host)
        return try NIOSSLClientHandler(context: context, serverHostname: serverHostname)
    }

    func applyPostGreetingTLSPolicy(
        tlsTransportMode: TLSTransportMode,
        capabilities: [Capability]
    ) async throws {
        try validateOperation()
        let context = try capturedTransport()
        if Self.requiresMissingSTARTTLSError(tlsTransportMode: tlsTransportMode, capabilities: capabilities) {
            await closeTransport(context)
            throw IMAPError.connectionFailed("Server did not advertise STARTTLS on port \(port)")
        }

        if Self.requiresSTARTTLSUpgrade(tlsTransportMode: tlsTransportMode, capabilities: capabilities) {
            do {
                try await startTLS()
                try validateTransport(context)
            } catch {
                await closeTransport(context)
                throw error
            }
        }
    }

    func startTLS() async throws {
        let context = try capturedTransport()
        let token = operationToken
        if let startTLSUpgradeOverrideForTesting {
            try await startTLSUpgradeOverrideForTesting()
            try validateTransport(context)
            return
        }

        let command = IMAPStartTLSCommand()
        let accepted = try await executeCommandBody(command)
        try await lifecycleCheckpoint("tlsAccepted", context: context)

        guard accepted else {
            throw IMAPError.connectionFailed("Server rejected STARTTLS")
        }

        guard let channel = self.channel, channel.isActive else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }

        let host = self.host
        let certificateVerificationPolicy = self.certificateVerificationPolicy
        let minimumTLSVersion = self.minimumTLSVersion
        try await channel.eventLoop.submit {
            try self.validateTransport(context, token: token)
            let sslHandler = try Self.makeTLSHandler(
                for: channel,
                host: host,
                certificateVerificationPolicy: certificateVerificationPolicy,
                minimumTLSVersion: minimumTLSVersion
            )
            try channel.pipeline.syncOperations.addHandler(sslHandler, position: .first)
        }.get()
        try await lifecycleCheckpoint("tlsInstalled", context: context)

        let refreshedCapabilities = try await executeCommandBody(CapabilityCommand())
        try commit(on: context) { context.capabilities = Set(refreshedCapabilities) }
    }
}
