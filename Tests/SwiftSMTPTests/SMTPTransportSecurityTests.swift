import NIO
import NIOEmbedded
import NIOSSL
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SMTPTransportSecurityTests {
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
