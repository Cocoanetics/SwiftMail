import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOSSL

extension IMAPConnection {
    static func makeTLSHandler(
        for channel: Channel,
        host: String,
        certificateVerificationPolicy: MailCertificateVerificationPolicy
    ) throws -> NIOSSLClientHandler {
        let configuration = MailTLSConfiguration.makeClientConfiguration(
            certificateVerificationPolicy: certificateVerificationPolicy
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
        try await channel.eventLoop.submit {
            let sslHandler = try Self.makeTLSHandler(
                for: channel,
                host: host,
                certificateVerificationPolicy: certificateVerificationPolicy
            )
            try channel.pipeline.syncOperations.addHandler(sslHandler, position: .first)
        }.get()

        let refreshedCapabilities = try await executeCommandBody(CapabilityCommand())
        self.capabilities = Set(refreshedCapabilities)
    }
}
