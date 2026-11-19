import Foundation
import NIO
import NIOEmbedded
import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

/// Coverage for the RFC 2971 ID replay that runs after every successful
/// authentication when a client identification is configured (PR #193):
/// the replay itself, the post-auth capability refresh that makes the
/// ID-capability guard reliable for XOAUTH2, and the failure semantics —
/// a server refusing ID is tolerated, a connection-killing ID failure is not.
extension ClientIdentificationReplayTests {
    @Test
    func abortedIDReplayCannotPublishOldExplicitCredentials() async throws {
        let harness = AuthenticationRaceHarness()
        let connection = await harness.server.primaryConnection
        let old = try await harness.install(on: connection)
        let entered = IMAPTestSignal()
        let release = IMAPTestSignal()
        let ownerExited = IMAPTestSignal()
        connection.operationOwnerFinishedForTesting = ownerExited.signal
        connection.lifecycleCheckpointForTesting = { stage in
            if stage == "response:IDCommand" { entered.signal(); await release.wait() }
        }
        defer { release.signal(); connection.abortNow() }
        await harness.server.setClientIdentification(Self.identification)
        let login = Task { try await harness.server.login(username: "old", password: "old-secret") }
        let loginLine = try await harness.outbound(old)
        let loginTag = try #require(loginLine.split(separator: " ").first)
        try await harness.inbound(old, "\(loginTag) OK [CAPABILITY IMAP4rev1 ID] authenticated\r\n")
        let identify = try await harness.outbound(old)
        let idTag = try #require(identify.split(separator: " ").first)
        try await harness.inbound(old, "* ID NIL\r\n\(idTag) OK identified\r\n")
        await entered.wait()
        connection.abortNow()
        await #expect(throws: IMAPAbortReason.connectionAborted) { try await authenticationResult(login) }
        connection.lifecycleCheckpointForTesting = nil
        connection.operationOwnerFinishedForTesting = nil
        connection.replaceConnectForTesting { _ = try await harness.install(on: connection) }
        try await harness.server.connect()
        let fresh = try #require(connection.channel as? NIOAsyncTestingChannel)
        let newLogin = Task { try await harness.server.login(username: "fresh", password: "new-secret") }
        let freshLoginLine = try await harness.outbound(fresh)
        let freshTag = try #require(freshLoginLine.split(separator: " ").first)
        try await harness.inbound(fresh, "\(freshTag) OK [CAPABILITY IMAP4rev1] authenticated\r\n")
        try await authenticationResult(newLogin)
        release.signal()
        await ownerExited.wait()
        guard case .login(let username, _) = await harness.server.authentication?.method else {
            Issue.record("Fresh explicit login credentials were lost")
            return
        }
        #expect(username == "fresh")
        #expect(connection.isAuthenticated)
        #expect(connection.channel === fresh)
        #expect(try await fresh.readOutbound(as: ByteBuffer.self) == nil)
    }

}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ClientIdentificationReplayTests {
    private struct Harness {
        let connection: IMAPConnection
        let channel: NIOAsyncTestingChannel
    }

    private static let identification = Identification(name: "SwiftMailTests", version: "1.0")

    @Test(arguments: ["NO", "BAD"])
    func serverRefusingIDDoesNotFailAuthentication(refusal: String) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        do {
            let harness = try await makeHarness(group: group, capabilities: [])
            let authentication = IMAPServer.Authentication(
                method: .login(username: "testuser", password: "testpass"),
                identification: Self.identification
            )
            let authTask = Task {
                try await authentication.authenticate(on: harness.connection)
            }

            try await respondToLogin(
                harness: harness,
                okLine: "A001 OK [CAPABILITY IMAP4rev1 ID] LOGIN completed\r\n"
            )

            guard let idLine = try await nextOutboundLine(from: harness.channel) else {
                Issue.record("Expected outbound ID command after authentication")
                authTask.cancel()
                try await group.shutdownGracefully()
                return
            }
            #expect(idLine.hasPrefix("A002 ID ("))

            try await writeInboundLines(harness.channel, "A002 \(refusal) ID not permitted\r\n")

            try await authTask.value
            #expect(harness.connection.isAuthenticated)
            #expect(harness.connection.isConnected)

            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// Regression for review finding 1 on PR #193: a server that advertises ID
    /// only after authentication and answers AUTHENTICATE with a plain OK
    /// (no CAPABILITY response code) must still get the ID replay. The stale
    /// pre-authentication snapshot used to short-circuit the guard.
    @Test
    func xoauth2WithoutCapabilityDataRefreshesCapabilitiesBeforeReplay() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        do {
            let xoauth2 = Capability.authenticate(AuthenticationMechanism("XOAUTH2")!)
            let harness = try await makeHarness(group: group, capabilities: [xoauth2, .saslIR])
            let authentication = IMAPServer.Authentication(
                method: .xoauth2(email: "user@example.com", accessTokenProvider: { "token123" }),
                identification: Self.identification
            )
            let authTask = Task {
                try await authentication.authenticate(on: harness.connection)
            }

            guard let authLine = try await nextOutboundLine(from: harness.channel) else {
                Issue.record("Expected outbound AUTHENTICATE command")
                authTask.cancel()
                try await group.shutdownGracefully()
                return
            }
            #expect(authLine.hasPrefix("A001 AUTHENTICATE XOAUTH2 "))
            try await writeInboundLines(harness.channel, "A001 OK authenticated\r\n")

            guard let capabilityLine = try await nextOutboundLine(from: harness.channel) else {
                Issue.record("Expected capability refresh after AUTHENTICATE without capability data")
                authTask.cancel()
                try await group.shutdownGracefully()
                return
            }
            #expect(capabilityLine == "A002 CAPABILITY\r\n")
            try await writeInboundLines(
                harness.channel,
                "* CAPABILITY IMAP4rev1 AUTH=XOAUTH2 ID\r\nA002 OK CAPABILITY completed\r\n"
            )

            guard let idLine = try await nextOutboundLine(from: harness.channel) else {
                Issue.record("Expected outbound ID command after capability refresh")
                authTask.cancel()
                try await group.shutdownGracefully()
                return
            }
            #expect(idLine.hasPrefix("A003 ID ("))
            try await writeInboundLines(harness.channel, "* ID NIL\r\nA003 OK ID completed\r\n")

            try await authTask.value
            #expect(harness.connection.capabilitiesSnapshot.contains(.id))
            #expect(harness.connection.isAuthenticated)

            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// Regression for review finding 2 on PR #193: when the server closes the
    /// socket during the ID replay, the connection is recycled and left
    /// unauthenticated — reporting authentication success anyway would hand
    /// callers a dead connection. The failure must propagate.
    @Test
    func connectionDeathDuringIDFailsAuthentication() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        do {
            let harness = try await makeHarness(group: group, capabilities: [])
            let authentication = IMAPServer.Authentication(
                method: .login(username: "testuser", password: "testpass"),
                identification: Self.identification
            )
            let authTask = Task {
                try await authentication.authenticate(on: harness.connection)
            }

            try await respondToLogin(
                harness: harness,
                okLine: "A001 OK [CAPABILITY IMAP4rev1 ID] LOGIN completed\r\n"
            )

            guard let idLine = try await nextOutboundLine(from: harness.channel) else {
                Issue.record("Expected outbound ID command after authentication")
                authTask.cancel()
                try await group.shutdownGracefully()
                return
            }
            #expect(idLine.hasPrefix("A002 ID ("))

            try await harness.channel.close().get()

            do {
                try await authTask.value
                Issue.record("Expected authentication to fail when the connection dies during ID")
            } catch is CancellationError {
                Issue.record("Expected a connection failure, got CancellationError")
            } catch {
                // Expected: the ID failure recycled the connection, so the
                // authentication as a whole must report failure.
            }

            #expect(!harness.connection.isAuthenticated)
            #expect(!harness.connection.isConnected)

            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test
    func skipsIDWhenServerDoesNotAdvertiseIt() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        do {
            let harness = try await makeHarness(group: group, capabilities: [])
            let authentication = IMAPServer.Authentication(
                method: .login(username: "testuser", password: "testpass"),
                identification: Self.identification
            )
            let authTask = Task {
                try await authentication.authenticate(on: harness.connection)
            }

            try await respondToLogin(
                harness: harness,
                okLine: "A001 OK [CAPABILITY IMAP4rev1] LOGIN completed\r\n"
            )

            try await authTask.value
            #expect(harness.connection.isAuthenticated)

            let unexpected = try await nextOutboundLine(
                from: harness.channel,
                timeoutNanoseconds: 200_000_000
            )
            #expect(unexpected == nil, "No ID command may be sent when the server does not advertise it")

            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    // MARK: - Harness

    private func makeHarness(
        group: MultiThreadedEventLoopGroup,
        capabilities: Set<NIOIMAPCore.Capability>
    ) async throws -> Harness {
        let connection = IMAPConnection(
            host: "localhost",
            port: 143,
            transportSecurity: .plainText,
            // Explicit since the designated initializer dropped its defaults: forgetting the
            // security policy is now a build error rather than a silently lax connection.
            minimumTLSVersion: .tlsv12,
            group: group,
            loggerLabel: "test.imap",
            outboundLabel: "test.imap.out",
            inboundLabel: "test.imap.in",
            connectionID: "test-id-replay",
            connectionRole: "test",
            parserLimits: .default,
            minimumCommandTimeoutSeconds: 0
        )
        let channel = NIOAsyncTestingChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 143)
        try await channel.connect(to: address)
        try await channel.addIMAPClientHandler()
        try await channel.pipeline.addHandler(connection.duplexLogger)
        try await channel.pipeline.addHandler(connection.responseBuffer)
        connection.replaceChannelForTesting(channel)
        connection.replaceCapabilitiesForTesting(capabilities)

        return Harness(connection: connection, channel: channel)
    }

    /// Consumes the outbound LOGIN command and answers it with `okLine`.
    private func respondToLogin(harness: Harness, okLine: String) async throws {
        guard let loginLine = try await nextOutboundLine(from: harness.channel) else {
            Issue.record("Expected outbound LOGIN command")
            return
        }
        #expect(loginLine.hasPrefix("A001 LOGIN "))
        try await writeInboundLines(harness.channel, okLine)
    }

    private func writeInboundLines(_ channel: NIOAsyncTestingChannel, _ text: String) async throws {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        try await channel.writeInbound(buffer)
    }

    private func nextOutboundLine(
        from channel: NIOAsyncTestingChannel,
        timeoutNanoseconds: UInt64 = 10_000_000_000
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

#if os(macOS)
    /// End-to-end coverage of the public path: `setClientIdentification` followed
    /// by `login` must send ID on the primary connection before the caller's
    /// first SELECT.
    @Suite(.serialized, .timeLimit(.minutes(1)))
    struct ClientIdentificationIntegrationTests {
        @Test(.timeLimit(.minutes(1)))
        func loginReplaysConfiguredIdentification() async throws {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            try FileManager.default.createDirectory(at: maildir, withIntermediateDirectories: true, attributes: nil)
            defer {
                try? FileManager.default.removeItem(at: tempRoot)
            }

            let testServer = try IMAPTestServer(
                host: "localhost",
                port: 0,
                username: "testuser",
                password: "testpass",
                maildirURL: maildir
            )
            try testServer.start()

            try await testServer.run {
                let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()
                await server.setClientIdentification(Identification(name: "SwiftMailTests", version: "1.0"))
                try await server.login(username: "testuser", password: "testpass")
                #expect(testServer.idCommandCount == 1)

                let status = try await server.selectMailbox("INBOX")
                #expect(status.messageCount == 0)
                try await server.disconnect()
            }
        }
    }
#endif
