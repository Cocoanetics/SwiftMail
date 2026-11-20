import Foundation
import NIO
import Testing
@testable import SwiftMail

/// `minimumCommandTimeoutSeconds` gives a slow server more time than a command's own timeout,
/// on every transport, and leaves longer timeouts alone.
@Suite("Minimum command timeout")
struct MinimumCommandTimeoutTests {
    @Test
    func itNeverShortensATimeout() async throws {
        let server = IMAPServer(
            host: "127.0.0.1", port: 1, transportSecurity: .plainText, minimumCommandTimeoutSeconds: 30)
        #expect(await server.minimumCommandTimeoutSeconds == 30)
        let named = await server.makeNamedConnection(name: "slow")
        #expect(named.timeout(5) == 30)
        #expect(named.timeout(60) == 60)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let idle = await server.makeIdleConnection(sessionID: UUID(), mailbox: "INBOX", group: group)
        #expect(idle.timeout(10) == 30)
        try await group.shutdownGracefully()

        let unchanged = IMAPServer(host: "127.0.0.1", port: 1, transportSecurity: .plainText)
        #expect(await unchanged.makeNamedConnection(name: "default").timeout(5) == 5)
    }

    #if os(macOS) || os(Linux)
        /// LOGIN's own timeout is 5 seconds; this server answers it after 5.5.
        @Test(.timeLimit(.minutes(1)))
        func aSlowLoginGetsThroughWithTheMinimum() async throws {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            for folder in ["cur", "new"] {
                try FileManager.default.createDirectory(
                    at: maildir.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let testServer = try IMAPTestServer(loginResponseDelay: 5.5, maildirURL: maildir)
            try testServer.start()
            try await testServer.run {
                let server = IMAPServer(
                    host: "127.0.0.1", port: testServer.port, transportSecurity: .plainText,
                    minimumCommandTimeoutSeconds: 10)
                try await server.connect()
                try await server.login(username: "testuser", password: "testpass")
                #expect(testServer.commandLog.filter { $0.contains("LOGIN") }.count == 1)
                try? await server.disconnect()
            }
        }
    #endif
}
