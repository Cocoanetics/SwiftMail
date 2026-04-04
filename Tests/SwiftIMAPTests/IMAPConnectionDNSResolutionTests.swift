import NIO
import Testing
@testable import SwiftMail

#if os(macOS)
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPConnectionDNSResolutionTests {

    private func makeGroup() -> MultiThreadedEventLoopGroup {
        MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    private func shutdownGroup(_ group: MultiThreadedEventLoopGroup) {
        try? group.syncShutdownGracefully()
    }

    /// Connecting to an unresolvable host should throw an error (not crash via
    /// HappyEyeballsConnector's leaked-promise assertion).
    @Test
    func connectToUnresolvableHostThrowsWithoutCrash() async {
        let group = makeGroup()
        defer { shutdownGroup(group) }

        let connection = IMAPConnection(
            host: "this-host-does-not-exist.invalid",
            port: 993,
            useTLS: false,
            group: group,
            loggerLabel: "test.dns",
            outboundLabel: "test.dns.out",
            inboundLabel: "test.dns.in",
            connectionID: "test-dns-unresolvable",
            connectionRole: "test"
        )

        do {
            try await connection.connect()
            Issue.record("Expected connect to unresolvable host to throw")
        } catch {
            // Any error is acceptable — the point is it doesn't crash.
            #expect(!connection.isConnected)
        }
    }

    /// Connecting to a host that resolves but refuses the TCP connection should
    /// throw cleanly without leaking NIO promises.
    @Test
    func connectToRefusedPortThrowsWithoutCrash() async {
        let group = makeGroup()
        defer { shutdownGroup(group) }

        // Port 1 is almost certainly not listening.
        let connection = IMAPConnection(
            host: "127.0.0.1",
            port: 1,
            useTLS: false,
            group: group,
            loggerLabel: "test.refused",
            outboundLabel: "test.refused.out",
            inboundLabel: "test.refused.in",
            connectionID: "test-refused-port",
            connectionRole: "test"
        )

        do {
            try await connection.connect()
            Issue.record("Expected connect to refused port to throw")
        } catch {
            #expect(!connection.isConnected)
        }
    }
}
#endif
