import Foundation
import Logging
import NIO
import NIOEmbedded
import Testing
@testable import SwiftMail

@Suite("Command Timeout Timer")
struct CommandTimeoutTimerTests {
    private func activeChannel() throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        _ = channel.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 1))
        try #require(channel.isActive)
        return channel
    }

    @Test("a response that arrives in time keeps the connection open")
    func responseInTimeDisarmsTheTimer() throws {
        let channel = try activeChannel()
        let promise = channel.eventLoop.makePromise(of: Int.self)
        IMAPConnection.armCommandTimeout(
            channel: channel, timeoutSeconds: 5, promise: promise, logger: Logger(label: "test"))

        // The handler completes the promise on the event loop; the task that
        // would cancel the timer has not resumed yet.
        promise.succeed(1)
        channel.embeddedEventLoop.advanceTime(by: .seconds(6))

        #expect(channel.isActive)
        #expect(try promise.futureResult.wait() == 1)
    }

    @Test("no response by the deadline fails the command and closes the connection")
    func missedDeadlineFailsAndCloses() throws {
        let channel = try activeChannel()
        let promise = channel.eventLoop.makePromise(of: Int.self)
        IMAPConnection.armCommandTimeout(
            channel: channel, timeoutSeconds: 5, promise: promise, logger: Logger(label: "test"))

        channel.embeddedEventLoop.advanceTime(by: .seconds(6))

        #expect(!channel.isActive)
        #expect(throws: IMAPError.self) { try promise.futureResult.wait() }
    }
}

#if os(macOS)
    @Suite("Command Timeout", .serialized, .timeLimit(.minutes(1)))
    struct CommandTimeoutTests {
        @Test("timeout ends a command whose literal continuation never arrives")
        func timeoutEndsCommandStuckOnLiteralContinuation() async throws {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("cur"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("new"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            // No LITERAL+, so a non-ASCII password goes out as a synchronizing
            // literal and LOGIN's write waits for a `+` that never comes.
            let testServer = try IMAPTestServer(
                advertisedCapabilities: ["IMAP4rev1", "AUTH=PLAIN"],
                withholdsLiteralContinuation: true,
                maildirURL: maildir
            )
            try testServer.start()

            try await testServer.run {
                let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()

                let start = Date()
                do {
                    try await server.login(username: "testuser", password: "päss")
                    Issue.record("LOGIN should have timed out")
                } catch IMAPError.timeout {
                    // expected
                }
                #expect(Date().timeIntervalSince(start) < 15)
                try? await server.disconnect()
            }
        }
    }
#endif
