import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOSSL

extension IMAPConnection {
    /// - Note: `minimumTLSVersion` has **no default on purpose.** It used to default to
    ///   `.tlsv1_2`, and the implicit-TLS call site simply omitted it — so a caller asking for
    ///   `.tlsv1_3` on port 993 silently got a TLS 1.2 floor. A default here makes forgetting the
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
        if Self.requiresMissingSTARTTLSError(tlsTransportMode: tlsTransportMode, capabilities: capabilities) {
            await closeAndClearChannelAfterSTARTTLSPolicyFailure()
            throw IMAPError.connectionFailed("Server did not advertise STARTTLS on port \(port)")
        }

        if Self.requiresSTARTTLSUpgrade(tlsTransportMode: tlsTransportMode, capabilities: capabilities) {
            do {
                try await startTLS()
            } catch {
                await closeAndClearChannelAfterSTARTTLSPolicyFailure()
                throw error
            }
        }
    }

    func closeAndClearChannelAfterSTARTTLSPolicyFailure() async {
        capabilities = []
        try? await disconnectBody()
    }

    func startTLS() async throws {
        if let startTLSUpgradeOverrideForTesting {
            try await startTLSUpgradeOverrideForTesting()
            return
        }

        let command = IMAPStartTLSCommand()
        let accepted = try await executeCommandBody(command)

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
            let sslHandler = try Self.makeTLSHandler(
                for: channel,
                host: host,
                certificateVerificationPolicy: certificateVerificationPolicy,
                minimumTLSVersion: minimumTLSVersion
            )
            try channel.pipeline.syncOperations.addHandler(sslHandler, position: .first)
        }.get()

        let refreshedCapabilities = try await executeCommandBody(CapabilityCommand())
        self.capabilities = Set(refreshedCapabilities)
    }
}
