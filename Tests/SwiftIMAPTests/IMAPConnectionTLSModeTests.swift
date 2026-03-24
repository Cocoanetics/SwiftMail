import NIO
import NIOIMAPCore
import NIOEmbedded
import Testing
@testable import SwiftMail

#if false
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPConnectionTLSModeTests {
    @Test
    func infersImplicitTLSOnPort993() throws {
        #expect(try IMAPConnection.resolveTLSTransportMode(port: 993, useTLS: nil) == .implicitTLS)
    }

    @Test
    func infersOpportunisticSTARTTLSOnPort143() throws {
        #expect(
            try IMAPConnection.resolveTLSTransportMode(port: 143, useTLS: nil) == .startTLSIfAvailable(requireTLS: false)
        )
    }

    @Test
    func requiresExplicitTLSChoiceOnNonStandardPorts() {
        do {
            _ = try IMAPConnection.resolveTLSTransportMode(port: 1143, useTLS: nil)
            Issue.record("Expected non-standard ports to require explicit useTLS")
        } catch let error as IMAPError {
            guard case .invalidArgument(let message) = error else {
                Issue.record("Expected invalidArgument, got \(error)")
                return
            }

            #expect(message.contains("requires explicit useTLS"))
        } catch {
            Issue.record("Expected IMAPError.invalidArgument, got \(error)")
        }
    }

    @Test
    func explicitTLSOnPort143RequiresSTARTTLSSupport() throws {
        let mode = try IMAPConnection.resolveTLSTransportMode(port: 143, useTLS: true)
        #expect(mode == .startTLSIfAvailable(requireTLS: true))
    }

    @Test
    func startTLSPolicyOnlyUpgradesWhenServerAdvertisesCapability() throws {
        let mode = try IMAPConnection.resolveTLSTransportMode(port: 143, useTLS: nil)

        #expect(
            IMAPConnection.requiresSTARTTLSUpgrade(
                port: 143,
                tlsTransportMode: mode,
                capabilities: [.startTLS, .idle]
            )
        )

        #expect(
            !IMAPConnection.requiresSTARTTLSUpgrade(
                port: 143,
                tlsTransportMode: mode,
                capabilities: [.idle]
            )
        )
    }

    @Test
    func requiredTLSDisconnectsPlaintextChannelWhenStartTLSIsUnavailable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            Task {
                try? await group.shutdownGracefully()
            }
        }

        let connection = IMAPConnection(
            host: "localhost",
            port: 143,
            useTLS: true,
            group: group,
            loggerLabel: "test.imap",
            outboundLabel: "test.imap.out",
            inboundLabel: "test.imap.in",
            connectionID: "test-starttls-required",
            connectionRole: "test"
        )
        let channel = EmbeddedChannel()
        connection.replaceChannelForTesting(channel)

        do {
            try await connection.applyPostGreetingTLSPolicy(
                tlsTransportMode: IMAPConnection.TLSTransportMode.startTLSIfAvailable(requireTLS: true),
                capabilities: []
            )
            Issue.record("Expected required TLS policy to reject a plaintext channel without STARTTLS")
        } catch let error as IMAPError {
            guard case .connectionFailed(let message) = error else {
                Issue.record("Expected connectionFailed, got \(error)")
                return
            }

            #expect(message == "Server did not advertise STARTTLS on port 143")
        }

        #expect(!connection.isConnected)
    }
}
#endif
