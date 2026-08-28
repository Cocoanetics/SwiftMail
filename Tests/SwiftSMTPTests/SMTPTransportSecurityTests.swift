import NIO
import NIOEmbedded
import NIOSSL
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SMTPTransportSecurityTests {
    private func captureEHLOCommand(
        from channel: NIOAsyncTestingChannel,
        while operation: @escaping @Sendable () async throws -> Void
    ) async throws -> String {
        let operationTask = Task {
            try await operation()
        }

        for _ in 0..<200 {
            if var outbound = try await channel.readOutbound(as: ByteBuffer.self) {
                let command = outbound.readString(length: outbound.readableBytes) ?? ""
                try await channel.writeInbound(
                    SMTPResponse(
                        code: 250,
                        message: "250-smtp.test greets you\n250 STARTTLS"
                    )
                )
                try await operationTask.value
                return command
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        operationTask.cancel()
        try? await channel.close().get()
        _ = await operationTask.result
        throw SMTPError.connectionFailed("Expected an outbound EHLO command")
    }

    private func ehloCommandsAcrossSTARTTLS(clientIdentity: String) async throws -> [String] {
        let server = SMTPServer(
            host: "smtp.example.com",
            port: 587,
            clientIdentity: clientIdentity
        )
        let channel = NIOAsyncTestingChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 587)
        try await channel.connect(to: address)
        await server.replaceChannelForTesting(channel)

        let initialCommand = try await captureEHLOCommand(from: channel) {
            _ = try await server.fetchCapabilities()
        }
        let postSTARTTLSCommand = try await captureEHLOCommand(from: channel) {
            // Isolate the SMTP state transition from the TLS byte transport.
            // Production performs this same capability refresh after installing TLS.
            try await server.applyPostEHLOTLSPolicy(
                transportMode: .startTLSRequired,
                capabilities: ["STARTTLS"],
                startTLSOverrideForTesting: {}
            )
        }

        await server.replaceChannelForTesting(nil)
        try await channel.close().get()
        return [initialCommand, postSTARTTLSCommand]
    }

    @Test
    func smtpServerUsesPrivacySafeDefaultClientIdentity() async {
        let server = SMTPServer(host: "smtp.example.com", port: 587)

        #expect(await server.clientIdentity == SMTPServer.defaultClientIdentity)
        #expect(SMTPServer.defaultClientIdentity == "[127.0.0.1]")
    }

    @Test
    func smtpServerStoresConfiguredClientIdentity() async {
        let server = SMTPServer(
            host: "smtp.example.com",
            port: 587,
            clientIdentity: "mail.example.com"
        )

        #expect(await server.clientIdentity == "mail.example.com")
    }

    @Test
    func defaultClientIdentityIsUsedBeforeAndAfterSTARTTLS() async throws {
        let commands = try await ehloCommandsAcrossSTARTTLS(
            clientIdentity: SMTPServer.defaultClientIdentity
        )

        #expect(commands == [
            "EHLO [127.0.0.1]\r\n",
            "EHLO [127.0.0.1]\r\n"
        ])
    }

    @Test
    func configuredClientIdentityIsUsedBeforeAndAfterSTARTTLS() async throws {
        let commands = try await ehloCommandsAcrossSTARTTLS(clientIdentity: "mail.example.com")

        #expect(commands == [
            "EHLO mail.example.com\r\n",
            "EHLO mail.example.com\r\n"
        ])
    }

    @Test
    func clientIdentityRejectsSMTPCommandInjection() {
        let command = EHLOCommand(clientIdentity: "mail.example.com\r\nNOOP")

        #expect(throws: SMTPError.self) {
            try command.validate()
        }
    }

    @Test
    func smtpServerDefaultsToFullCertificateVerification() async {
        let server = SMTPServer(host: "smtp.example.com", port: 587)

        #expect(await server.certificateVerificationPolicyForTesting == .fullVerification)
    }

    @Test
    func smtpServerStoresExplicitNoCertificateVerificationPolicy() async {
        let server = SMTPServer(
            host: "127.0.0.1",
            port: 1025,
            transportSecurity: .startTLS,
            certificateVerificationPolicy: .noVerification
        )

        #expect(await server.certificateVerificationPolicyForTesting == .noVerification)
    }

    @Test
    func explicitSTARTTLSRequiresAdvertisedUpgrade() {
        #expect(
            SMTPServer.requiresSTARTTLSUpgrade(
                transportMode: .startTLSRequired,
                capabilities: ["SIZE", "STARTTLS", "AUTH PLAIN"]
            )
        )
    }

    @Test
    func explicitSTARTTLSRequiresMissingSTARTTLSErrorWhenNotAdvertised() {
        #expect(
            SMTPServer.requiresMissingSTARTTLSError(
                transportMode: .startTLSRequired,
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )
    }

    @Test
    func implicitTLSSkipsSTARTTLSPolicyHelpers() {
        #expect(
            !SMTPServer.requiresSTARTTLSUpgrade(
                transportMode: .implicitTLS,
                capabilities: ["SIZE", "STARTTLS", "AUTH PLAIN"]
            )
        )

        #expect(
            !SMTPServer.requiresMissingSTARTTLSError(
                transportMode: .implicitTLS,
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )
    }

    @Test
    func automaticTransportSecurityPreservesPortInferredBehavior() {
        #expect(SMTPServer.resolveTransportMode(port: 465, transportSecurity: .automatic) == .implicitTLS)
        #expect(SMTPServer.resolveTransportMode(port: 587, transportSecurity: .automatic) == .startTLSIfAvailable)
        #expect(SMTPServer.resolveTransportMode(port: 1025, transportSecurity: .automatic) == .plainText)
    }

    @Test
    func automatic587DoesNotRequireSTARTTLSWhenCapabilityIsMissing() {
        let transportMode = SMTPServer.resolveTransportMode(port: 587, transportSecurity: .automatic)

        #expect(
            !SMTPServer.requiresMissingSTARTTLSError(
                transportMode: transportMode,
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )
    }

    @Test
    func automatic587RequestsSTARTTLSWhenCapabilityIsAdvertised() {
        let transportMode = SMTPServer.resolveTransportMode(port: 587, transportSecurity: .automatic)

        #expect(
            SMTPServer.requiresSTARTTLSUpgrade(
                transportMode: transportMode,
                capabilities: ["SIZE", "STARTTLS", "AUTH PLAIN"]
            )
        )
    }

    @Test
    func explicitSTARTTLSMissingCapabilityClearsChannelThroughPolicy() async throws {
        let server = SMTPServer(host: "localhost", port: 587, transportSecurity: .startTLS)
        let channel = EmbeddedChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 587)
        try await channel.connect(to: address).get()

        await server.replaceChannelForTesting(channel)

        do {
            try await server.applyPostEHLOTLSPolicy(
                transportMode: .startTLSRequired,
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
            Issue.record("Expected missing STARTTLS capability failure")
        } catch let error as SMTPError {
            if case .tlsFailed(let message) = error {
                #expect(message.contains("STARTTLS required but not advertised"))
            } else {
                Issue.record("Expected tlsFailed error, got \(error)")
            }
        }

        #expect(await !server.hasChannelForTesting)
        #expect(!channel.isActive)
    }

    @Test
    func advertisedSTARTTLSUpgradeFailureClearsChannelThroughPolicy() async throws {
        let server = SMTPServer(host: "localhost", port: 587, transportSecurity: .startTLS)
        let channel = EmbeddedChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 587)
        try await channel.connect(to: address).get()

        await server.replaceChannelForTesting(channel)

        do {
            try await server.applyPostEHLOTLSPolicy(
                transportMode: .startTLSRequired,
                capabilities: ["SIZE", "STARTTLS", "AUTH PLAIN"],
                startTLSOverrideForTesting: {
                    throw SMTPError.tlsFailed("Injected STARTTLS failure")
                }
            )
            Issue.record("Expected STARTTLS upgrade failure")
        } catch let error as SMTPError {
            if case .tlsFailed(let message) = error {
                #expect(message.contains("STARTTLS upgrade failed"))
            } else {
                Issue.record("Expected tlsFailed error, got \(error)")
            }
        }

        #expect(await !server.hasChannelForTesting)
        #expect(!channel.isActive)
    }
}
