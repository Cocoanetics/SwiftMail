import Foundation
import NIO
import NIOEmbedded
import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

/// The pre-authentication mechanism guard must judge a live capability
/// snapshot. A disconnect clears the snapshot with the channel, so checking
/// it before `prepareAuthenticationChannel` reported every re-authentication
/// on a dropped connection as "not advertised by server" without contacting
/// the server, and the connection never recovered on its own.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct AuthenticationCapabilityGuardTests {
    private struct Harness {
        let connection: IMAPConnection
        let channel: NIOAsyncTestingChannel
    }

    @Test
    func emptySnapshotIsRefreshedBeforeJudgingXOAUTH2() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let harness = try await makeLiveHarness(group: group, capabilities: [])

        let authTask = Task {
            try await harness.connection.authenticateXOAUTH2(email: "user@example.com", accessToken: "token")
        }
        try await answerCapabilityRefresh(
            harness,
            tag: "A001",
            capabilities: "IMAP4rev1 SASL-IR AUTH=XOAUTH2"
        )
        try await answerAuthenticate(harness, tag: "A002", mechanism: "XOAUTH2")
        try await answerCapabilityRefresh(harness, tag: "A003", capabilities: "IMAP4rev1 AUTH=XOAUTH2")

        try await authTask.value
        #expect(harness.connection.isAuthenticated)
        await shutDownGracefully(group)
    }

    @Test
    func emptySnapshotIsRefreshedBeforeJudgingPLAIN() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let harness = try await makeLiveHarness(group: group, capabilities: [])

        let authTask = Task {
            try await harness.connection.authenticatePlain(username: "user", password: "secret")
        }
        try await answerCapabilityRefresh(
            harness,
            tag: "A001",
            capabilities: "IMAP4rev1 SASL-IR AUTH=PLAIN"
        )
        try await answerAuthenticate(harness, tag: "A002", mechanism: "PLAIN")
        try await answerCapabilityRefresh(harness, tag: "A003", capabilities: "IMAP4rev1 AUTH=PLAIN")

        try await authTask.value
        #expect(harness.connection.isAuthenticated)
        await shutDownGracefully(group)
    }

    @Test
    func refreshedSnapshotWithoutTheMechanismIsStillRejected() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let harness = try await makeLiveHarness(group: group, capabilities: [])

        let authTask = Task {
            try await harness.connection.authenticateXOAUTH2(email: "user@example.com", accessToken: "token")
        }
        try await answerCapabilityRefresh(harness, tag: "A001", capabilities: "IMAP4rev1 AUTH=PLAIN")

        do {
            try await authTask.value
            Issue.record("Expected XOAUTH2 to be rejected after the refresh")
        } catch let error as IMAPError {
            guard case .unsupportedAuthMechanism(let reason) = error else {
                Issue.record("Unexpected IMAP error: \(error)")
                return
            }
            #expect(reason == "XOAUTH2 not advertised by server")
        }
        #expect(!harness.connection.isAuthenticated)
        await shutDownGracefully(group)
    }

    @Test
    func disconnectedConnectionReconnectsBeforeJudgingTheMechanism() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        // Port 1 refuses immediately: the transport attempt fails, which is the
        // point. Before the fix the empty snapshot short-circuited to
        // "not advertised" without any connection attempt.
        let connection = makeConnection(group: group, port: 1)

        do {
            try await connection.authenticateXOAUTH2(email: "user@example.com", accessToken: "token")
            Issue.record("Expected the transport attempt to fail")
        } catch let error as IMAPError {
            guard case .unsupportedAuthMechanism = error else { return }
            Issue.record("Disconnected connection judged the mechanism instead of reconnecting: \(error)")
        } catch {
            // Any transport-level failure is the expected outcome.
        }
        await shutDownGracefully(group)
    }

    /// The empty-snapshot refresh runs through `executeCommandBody`, which recycles a
    /// buffered BYE or reconnects a dead transport. Authentication must then use the
    /// replacement, not the channel captured before the refresh: writing on the stale
    /// one failed, and that failure's `disconnectBody()` closed the healthy replacement
    /// too (review on #221).
    @Test
    func refreshThatReplacedTheChannelAuthenticatesOnTheReplacement() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let stale = try await makeLiveHarness(group: group, capabilities: [])
        let connection = stale.connection
        let replacementChannel = NIOAsyncTestingChannel()
        connection.replaceCapabilityRefreshForTesting {
            // The transport died under the refresh; the connection reconnected and
            // took its capabilities from the new channel.
            try await stale.channel.close()
            try await replacementChannel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 143))
            try await replacementChannel.addIMAPClientHandler()
            try await replacementChannel.pipeline.addHandler(connection.duplexLogger)
            try await replacementChannel.pipeline.addHandler(connection.responseBuffer)
            connection.replaceChannelForTesting(replacementChannel)
            connection.replaceCapabilitiesForTesting([
                Capability("IMAP4rev1"),
                Capability("SASL-IR"),
                .authenticate(AuthenticationMechanism("PLAIN"))
            ])
        }
        let replacement = Harness(connection: connection, channel: replacementChannel)
        let authTask = Task {
            try await connection.authenticatePlain(username: "user", password: "secret")
        }
        try await answerAuthenticate(replacement, tag: "A001", mechanism: "PLAIN")
        try await answerCapabilityRefresh(replacement, tag: "A002", capabilities: "IMAP4rev1 AUTH=PLAIN")
        try await authTask.value
        #expect(connection.isAuthenticated)
        let staleWrite = try? await stale.channel.readOutbound(as: ByteBuffer.self)
        #expect(staleWrite == nil, "nothing may be written on the transport the refresh replaced")
        await shutDownGracefully(group)
    }

    // MARK: - Harness

    private func makeConnection(group: MultiThreadedEventLoopGroup, port: Int) -> IMAPConnection {
        IMAPConnection(
            host: "127.0.0.1",
            port: port,
            transportSecurity: .plainText,
            minimumTLSVersion: .tlsv12,
            group: group,
            loggerLabel: "test.imap",
            outboundLabel: "test.imap.out",
            inboundLabel: "test.imap.in",
            connectionID: "test-auth-guard",
            connectionRole: "test",
            parserLimits: .default
        )
    }

    private func makeLiveHarness(
        group: MultiThreadedEventLoopGroup,
        capabilities: Set<NIOIMAPCore.Capability>
    ) async throws -> Harness {
        let connection = makeConnection(group: group, port: 143)
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 143))
        try await channel.addIMAPClientHandler()
        try await channel.pipeline.addHandler(connection.duplexLogger)
        try await channel.pipeline.addHandler(connection.responseBuffer)
        connection.replaceChannelForTesting(channel)
        connection.replaceCapabilitiesForTesting(capabilities)
        return Harness(connection: connection, channel: channel)
    }

    private func answerCapabilityRefresh(_ harness: Harness, tag: String, capabilities: String) async throws {
        let line = try await nextOutboundLine(from: harness.channel)
        #expect(line == "\(tag) CAPABILITY\r\n", "expected a CAPABILITY refresh, got \(line ?? "<nothing>")")
        try await writeInboundLines(
            harness.channel,
            "* CAPABILITY \(capabilities)\r\n\(tag) OK CAPABILITY completed\r\n"
        )
    }

    private func answerAuthenticate(_ harness: Harness, tag: String, mechanism: String) async throws {
        let line = try await nextOutboundLine(from: harness.channel)
        #expect(
            line?.hasPrefix("\(tag) AUTHENTICATE \(mechanism) ") == true,
            "expected an AUTHENTICATE \(mechanism) with SASL-IR, got \(line ?? "<nothing>")"
        )
        try await writeInboundLines(harness.channel, "\(tag) OK authenticated\r\n")
    }

    private func writeInboundLines(_ channel: NIOAsyncTestingChannel, _ text: String) async throws {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        try await channel.writeInbound(buffer)
    }

    private func nextOutboundLine(
        from channel: NIOAsyncTestingChannel,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async throws -> String? {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if var line = try await channel.readOutbound(as: ByteBuffer.self) {
                return line.readString(length: line.readableBytes)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }
}
