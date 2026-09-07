import Foundation
import NIO
import NIOEmbedded
import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

private actor ReauthenticationCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

/// A connection that lost an authenticated session recovers it inside the command
/// queue, on the transport it just reopened, before the command or IDLE that
/// reopened it is sent. The check and the command are one queue turn, so a peer
/// reset between them cannot leave an authenticated-state command on a fresh
/// unauthenticated socket, and concurrent callers cannot each authenticate.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ReauthenticationAfterReconnectTests {
    @Test
    func commandThatReopensTheTransportReauthenticatesFirst() async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group: group)
            let counter = ReauthenticationCounter()
            let replacement = try await loseAuthenticatedSession(on: connection, counter: counter)

            let noop = Task { try await connection.executeCommand(NoopCommand()) }
            let line = try await nextOutboundLine(from: replacement)
            #expect(line == "A001 NOOP\r\n", "expected NOOP on the replacement, got \(line ?? "<nothing>")")
            #expect(await counter.value() == 1, "re-authentication runs before the command goes out")
            try await writeInboundLines(replacement, "A001 OK NOOP completed\r\n")
            _ = try await noop.value
            #expect(connection.isAuthenticated)
            #expect(!connection.lostAuthenticatedSession)
        }
    }

    @Test
    func idleStartThatReopensTheTransportReauthenticatesFirst() async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group: group)
            let counter = ReauthenticationCounter()
            let replacement = try await loseAuthenticatedSession(on: connection, counter: counter)
            connection.replaceCapabilitiesForTesting([Capability("IMAP4rev1"), .idle])

            let stream = try await connection.idle()
            let line = try await nextOutboundLine(from: replacement)
            #expect(line == "A001 IDLE\r\n", "expected IDLE on the replacement, got \(line ?? "<nothing>")")
            #expect(await counter.value() == 1, "re-authentication runs before IDLE goes out")
            #expect(connection.isAuthenticated)
            _ = stream
            try? await connection.disconnect()
        }
    }

    @Test
    func reauthenticationWaitsWhileAuthenticationIsInProgress() async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group: group)
            let counter = ReauthenticationCounter()
            connection.lostAuthenticatedSession = true
            connection.reauthenticateAfterReconnect = { _ in await counter.increment() }

            connection.authenticationInProgress = true
            try await connection.reauthenticateIfSessionWasLost(before: "CAPABILITY")
            #expect(await counter.value() == 0, "the refresh inside an authentication must not nest another")

            connection.authenticationInProgress = false
            try await connection.reauthenticateIfSessionWasLost(before: "NOOP")
            #expect(await counter.value() == 1)
        }
    }

    @Test
    func authenticationFollowUpThatReopensTransportReauthenticatesBeforeReturning() async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group: group)
            let stale = try await makeTestingChannel(for: connection)
            let replacement = NIOAsyncTestingChannel()
            connection.replaceConnectForTesting {
                try await replacement.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 143))
                try await replacement.addIMAPClientHandler()
                try await replacement.pipeline.addHandler(connection.duplexLogger)
                try await replacement.pipeline.addHandler(connection.responseBuffer)
                connection.replaceChannelForTesting(replacement)
            }
            connection.authenticationFollowUpOverrideForTesting = {
                connection.authenticationFollowUpOverrideForTesting = nil
                try await stale.close()
            }

            let login = Task { try await connection.login(username: "user", password: "secret") }
            let firstLogin = try await nextOutboundLine(from: stale)
            #expect(firstLogin?.hasPrefix("A001 LOGIN ") == true, "got \(firstLogin ?? "<nothing>")")
            try await writeInboundLines(stale, "A001 OK LOGIN completed\r\n")

            let preAuthCapability = try await nextOutboundLine(from: replacement)
            #expect(
                preAuthCapability == "A002 CAPABILITY\r\n",
                "expected CAPABILITY on the replacement, got \(preAuthCapability ?? "<nothing>")"
            )
            try await writeInboundLines(
                replacement,
                "* CAPABILITY IMAP4rev1\r\nA002 OK CAPABILITY completed\r\n"
            )

            let retriedLogin = try await nextOutboundLine(from: replacement)
            #expect(
                retriedLogin?.hasPrefix("A003 LOGIN ") == true,
                "authentication must be retried on the replacement, got \(retriedLogin ?? "<nothing>")"
            )
            try await writeInboundLines(
                replacement,
                "A003 OK [CAPABILITY IMAP4rev1] LOGIN completed\r\n"
            )
            try await login.value
            #expect(connection.isAuthenticated)
            #expect(!connection.lostAuthenticatedSession)
        }
    }

    @Test
    func explicitDisconnectIsNotALostSession() async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group: group)
            let channel = try await makeTestingChannel(for: connection)
            connection.markSessionAuthenticated()

            try await connection.disconnect()
            #expect(!connection.lostAuthenticatedSession, "ending the session on purpose is not losing it")

            let second = try await makeTestingChannel(for: connection)
            connection.markSessionAuthenticated()
            try await second.close()
            connection.clearInvalidChannel()
            #expect(connection.lostAuthenticatedSession, "a dead channel under an authenticated session is a loss")
            _ = channel
        }
    }

    @Test
    func concurrentPrimaryCallersShareOneAuthentication() async throws {
        let server = SwiftMail.IMAPServer(host: "localhost", port: 143, useTLS: false)
        let primary = await server.primaryConnection
        let channel = try await makeTestingChannel(for: primary)
        primary.replaceCapabilitiesForTesting([
            Capability("IMAP4rev1"), Capability("SASL-IR"), .authenticate(AuthenticationMechanism("PLAIN"))
        ])
        await server.replaceAuthenticationForTesting(
            .init(method: .plain(username: "user", password: "secret"), identification: nil)
        )

        let first = Task { try await server.ensurePrimaryConnectionAuthenticated() }
        let second = Task { try await server.ensurePrimaryConnectionAuthenticated() }
        let authenticate = try await nextOutboundLine(from: channel)
        #expect(authenticate?.hasPrefix("A001 AUTHENTICATE PLAIN ") == true, "got \(authenticate ?? "<nothing>")")
        try await writeInboundLines(channel, "A001 OK authenticated\r\n")
        let refresh = try await nextOutboundLine(from: channel)
        #expect(refresh == "A002 CAPABILITY\r\n", "got \(refresh ?? "<nothing>")")
        try await writeInboundLines(channel, "* CAPABILITY IMAP4rev1 AUTH=PLAIN\r\nA002 OK done\r\n")
        try await first.value
        try await second.value
        let extra = try await nextOutboundLine(from: channel, timeoutNanoseconds: 200_000_000)
        #expect(extra == nil, "the second caller must not authenticate again, got \(extra ?? "<nothing>")")
        #expect(primary.isAuthenticated)
    }

    // MARK: - Harness

    private func makeConnection(group: MultiThreadedEventLoopGroup) -> IMAPConnection {
        IMAPConnection(
            host: "127.0.0.1",
            port: 143,
            transportSecurity: .plainText,
            minimumTLSVersion: .tlsv12,
            group: group,
            loggerLabel: "test.imap",
            outboundLabel: "test.imap.out",
            inboundLabel: "test.imap.in",
            connectionID: "test-reauth",
            connectionRole: "test",
            parserLimits: .default
        )
    }

    /// A live testing channel wired into the connection's pipeline and installed as its channel.
    private func makeTestingChannel(for connection: IMAPConnection) async throws -> NIOAsyncTestingChannel {
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 143))
        try await channel.addIMAPClientHandler()
        try await channel.pipeline.addHandler(connection.duplexLogger)
        try await channel.pipeline.addHandler(connection.responseBuffer)
        connection.replaceChannelForTesting(channel)
        return channel
    }

    /// Authenticates the connection on a channel, kills that channel as a peer reset
    /// would, and arranges for the next connect to install a replacement whose
    /// outbound the test can read. The counter records the re-authentication hook,
    /// which marks the session authenticated the way a real AUTHENTICATE would.
    private func loseAuthenticatedSession(
        on connection: IMAPConnection,
        counter: ReauthenticationCounter
    ) async throws -> NIOAsyncTestingChannel {
        let stale = try await makeTestingChannel(for: connection)
        connection.replaceCapabilitiesForTesting([Capability("IMAP4rev1")])
        connection.markSessionAuthenticated()
        try await stale.close()
        let replacement = NIOAsyncTestingChannel()
        connection.replaceConnectForTesting {
            try await replacement.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 143))
            try await replacement.addIMAPClientHandler()
            try await replacement.pipeline.addHandler(connection.duplexLogger)
            try await replacement.pipeline.addHandler(connection.responseBuffer)
            connection.replaceChannelForTesting(replacement)
        }
        connection.reauthenticateAfterReconnect = { connection in
            await counter.increment()
            connection.markSessionAuthenticated()
        }
        return replacement
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
