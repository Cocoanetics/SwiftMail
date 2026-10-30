import Foundation
import NIO
import NIOEmbedded
import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

private actor ConnectCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

/// A caller that must know about every session it runs commands on (a MOVE that must
/// not carry on in a session nobody opened) turns off the reconnect inside commands.
/// With it off, a command that finds its connection gone throws and opens nothing; the
/// caller reconnects on purpose with `connect()`. With it on, the default, the command
/// reopens the transport and re-authenticates as before.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ReconnectInsideCommandsTests {
    @Test
    func reconnectsInsideCommandsByDefault() async throws {
        let server = SwiftMail.IMAPServer(host: "localhost", port: 143, useTLS: false)
        #expect(await server.reconnectsInsideCommands)
    }

    @Test
    func commandOnADeadConnectionReconnectsWhenTheSwitchIsOn() async throws {
        let server = SwiftMail.IMAPServer(host: "localhost", port: 143, useTLS: false)
        let counter = ConnectCounter()
        let replacement = try await loseAuthenticatedSession(on: server, counter: counter)

        let select = Task { try await server.selectMailbox("INBOX") }
        let line = try await nextOutboundLine(from: replacement)
        #expect(
            line?.hasPrefix("A001 LOGIN ") == true,
            "expected LOGIN on a new connection, got \(line ?? "<nothing>")"
        )
        #expect(await counter.value() == 1)

        try await replacement.close()
        _ = try? await select.value
    }

    @Test
    func commandOnADeadConnectionThrowsWhenTheSwitchIsOff() async throws {
        let server = SwiftMail.IMAPServer(host: "localhost", port: 143, useTLS: false)
        await server.setReconnectsInsideCommands(false)
        let counter = ConnectCounter()
        let replacement = try await loseAuthenticatedSession(on: server, counter: counter, refuseConnect: true)

        await #expect(throws: IMAPError.self) {
            try await server.selectMailbox("INBOX")
        }
        #expect(await counter.value() == 0, "no new connection may be opened")
        let line = try await nextOutboundLine(from: replacement, timeoutNanoseconds: 200_000_000)
        #expect(line == nil, "nothing may be sent, got \(line ?? "<nothing>")")
        #expect(!(await server.isConnected))
    }

    @Test
    func everyCommandPathThrowsWhenTheSwitchIsOff() async throws {
        let server = SwiftMail.IMAPServer(host: "localhost", port: 143, useTLS: false)
        await server.setReconnectsInsideCommands(false)
        let counter = ConnectCounter()
        _ = try await loseAuthenticatedSession(on: server, counter: counter, refuseConnect: true)
        let primary = await server.primaryConnection
        primary.replaceCapabilitiesForTesting([Capability("IMAP4rev1"), .idle])

        await #expect(throws: IMAPError.self) { _ = try await server.noop() }
        await #expect(throws: IMAPError.self) { _ = try await primary.executeCommand(NoopCommand()) }
        await #expect(throws: IMAPError.self) { _ = try await primary.idle() }
        await #expect(throws: IMAPError.self) {
            try await primary.authenticatePlain(username: "user", password: "secret")
        }
        #expect(await counter.value() == 0, "no command path may open a new connection")
    }

    @Test
    func explicitConnectStillWorksWhenTheSwitchIsOff() async throws {
        let server = SwiftMail.IMAPServer(host: "localhost", port: 143, useTLS: false)
        await server.setReconnectsInsideCommands(false)
        let counter = ConnectCounter()
        _ = try await loseAuthenticatedSession(on: server, counter: counter)

        try await server.connect()
        #expect(await counter.value() == 1, "reconnecting on purpose is the caller's to do")
        #expect(await server.isConnected)
    }

    #if os(macOS)
        @Test
        func switchSetWhileANamedConnectionIsBeingCreatedReachesIt() async throws {
            let maildir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: maildir) }
            let testServer = try IMAPTestServer(
                host: "localhost",
                port: 0,
                username: "u",
                password: "p",
                loginResponseDelay: 0.3,
                maildirURL: maildir
            )
            try testServer.start()

            try await testServer.run {
                let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()
                try await server.login(username: "u", password: "p")

                let named = Task { try await server.connection(named: "mover") }
                // The named connection's LOGIN has gone out; its creation is suspended.
                while testServer.commandLog.filter({ $0.contains(" LOGIN ") }).count < 2 {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                await server.setReconnectsInsideCommands(false)
                _ = try await named.value

                let connection = await server.namedConnections["mover"]?.connection
                #expect(connection?.reconnectsInsideCommands == false)
                try await server.disconnect()
            }
        }
    #endif

    // MARK: - Harness

    /// Authenticates the server's primary connection on a channel, kills that channel as a
    /// peer reset would, and arranges for any later connect to install a replacement whose
    /// outbound the test can read. The counter records every connect. With
    /// `refuseConnect` the connect counts and then fails, so a regression fails the
    /// test at once instead of leaving a command waiting on a server that never answers.
    private func loseAuthenticatedSession(
        on server: SwiftMail.IMAPServer,
        counter: ConnectCounter,
        refuseConnect: Bool = false
    ) async throws -> NIOAsyncTestingChannel {
        let connection = await server.primaryConnection
        let stale = try await makeTestingChannel(for: connection)
        connection.replaceCapabilitiesForTesting([Capability("IMAP4rev1")])
        connection.markSessionAuthenticated()
        await server.replaceAuthenticationForTesting(
            .init(method: .login(username: "user", password: "secret"), identification: nil)
        )
        try await stale.close()

        let replacement = NIOAsyncTestingChannel()
        connection.replaceConnectForTesting {
            await counter.increment()
            if refuseConnect {
                throw IMAPError.connectionFailed("the test refused this connect")
            }
            try await replacement.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 143))
            try await replacement.addIMAPClientHandler()
            try await replacement.pipeline.addHandler(connection.duplexLogger)
            try await replacement.pipeline.addHandler(connection.responseBuffer)
            connection.replaceChannelForTesting(replacement)
        }
        return replacement
    }

    private func makeTestingChannel(for connection: IMAPConnection) async throws -> NIOAsyncTestingChannel {
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 143))
        try await channel.addIMAPClientHandler()
        try await channel.pipeline.addHandler(connection.duplexLogger)
        try await channel.pipeline.addHandler(connection.responseBuffer)
        connection.replaceChannelForTesting(channel)
        return channel
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
