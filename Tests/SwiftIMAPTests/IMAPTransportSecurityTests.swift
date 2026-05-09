import NIOIMAPCore
import NIO
import NIOEmbedded
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPTransportSecurityTests {
    @Test
    func explicitStartTLSRequiresUpgradeOnArbitraryPorts() throws {
        let mode = try IMAPConnection.resolveTLSTransportMode(port: 1143, transportSecurity: .startTLS)

        #expect(mode == .startTLSRequired)
    }

    @Test
    func startTLSRequiredUpgradesWhenCapabilityIsAdvertised() {
        #expect(
            IMAPConnection.requiresSTARTTLSUpgrade(
                tlsTransportMode: .startTLSRequired,
                capabilities: [.startTLS]
            )
        )
    }

    @Test
    func startTLSRequiredFailsClosedWhenCapabilityIsMissing() {
        #expect(
            IMAPConnection.requiresMissingSTARTTLSError(
                tlsTransportMode: .startTLSRequired,
                capabilities: [.idle]
            )
        )
    }

    @Test
    func explicitImplicitTLSOnArbitraryPortsSkipsStartTLS() throws {
        let mode = try IMAPConnection.resolveTLSTransportMode(port: 1143, transportSecurity: .implicitTLS)

        #expect(mode == .implicitTLS)
        #expect(
            !IMAPConnection.requiresSTARTTLSUpgrade(
                tlsTransportMode: mode,
                capabilities: [.startTLS]
            )
        )
    }

    @Test
    func automaticPreservesStandardIMAPPortBehavior() throws {
        #expect(
            try IMAPConnection.resolveTLSTransportMode(port: 993, transportSecurity: .automatic) == .implicitTLS
        )
        #expect(
            try IMAPConnection.resolveTLSTransportMode(port: 143, transportSecurity: .automatic) == .startTLSIfAvailable
        )
    }

    @Test
    func automaticRejectsAmbiguousCustomPorts() {
        var didThrowInvalidArgument = false

        do {
            _ = try IMAPConnection.resolveTLSTransportMode(port: 1143, transportSecurity: .automatic)
        } catch let error as IMAPError {
            if case .invalidArgument(let message) = error {
                didThrowInvalidArgument = message.contains("requires explicit transportSecurity")
            }
        } catch {
            didThrowInvalidArgument = false
        }

        #expect(didThrowInvalidArgument)
    }

    @Test
    func advertisedSTARTTLSFailureClearsChannel() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let connection = IMAPConnection(
                host: "localhost",
                port: 143,
                transportSecurity: .startTLS,
                group: group,
                loggerLabel: "test.imap",
                outboundLabel: "test.imap.out",
                inboundLabel: "test.imap.in",
                connectionID: "test-starttls-failure",
                connectionRole: "test"
            )
            let channel = EmbeddedChannel()
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: 143)
            try await channel.connect(to: address).get()

            connection.replaceChannelForTesting(channel)
            connection.replaceCapabilitiesForTesting([.idle, .startTLS])
            #expect(connection.isConnected)
            connection.replaceStartTLSUpgradeForTesting {
                throw IMAPError.connectionFailed("Injected STARTTLS failure")
            }

            do {
                try await connection.applyPostGreetingTLSPolicy(
                    tlsTransportMode: .startTLSRequired,
                    capabilities: [.startTLS]
                )
                Issue.record("Expected STARTTLS upgrade failure")
            } catch {
                #expect(!connection.isConnected)
            }

            #expect(connection.capabilitiesSnapshot.isEmpty)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }

        try await group.shutdownGracefully()
    }
}
