import Foundation
import Logging
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
import NIOIMAPCore
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

    @Test("no response by the deadline fails the command with a timeout")
    func missedDeadlineFailsTheCommand() throws {
        let channel = try activeChannel()
        let promise = channel.eventLoop.makePromise(of: Int.self)
        IMAPConnection.armCommandTimeout(
            channel: channel, timeoutSeconds: 5, promise: promise, logger: Logger(label: "test"))

        channel.embeddedEventLoop.advanceTime(by: .seconds(6))

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
                let server = SwiftMail.IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
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

        @Test(
            "a reply other than + to a pending literal fails the command promptly",
            arguments: ["* ((((\r\n", "{tag} NO literal rejected\r\n", "{close}"]
        )
        func nonContinuationReplyFailsPromptly(reply: String) async throws {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("cur"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("new"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let testServer = try IMAPTestServer(
                advertisedCapabilities: ["IMAP4rev1", "AUTH=PLAIN"],
                withholdsLiteralContinuation: true,
                withheldLiteralReply: reply,
                maildirURL: maildir
            )
            try testServer.start()

            try await testServer.run {
                let server = SwiftMail.IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()

                let start = Date()
                do {
                    try await server.login(username: "testuser", password: "päss")
                    Issue.record("LOGIN should have failed")
                } catch IMAPError.timeout {
                    Issue.record("LOGIN waited for the deadline instead of failing on the reply")
                } catch {
                    // expected: the reply itself fails the command
                }
                #expect(Date().timeIntervalSince(start) < 4)
                try? await server.disconnect()
            }
        }

        @Test("local preparation in send does not count against the server's deadline")
        func slowPreparationDoesNotTimeOut() async throws {
            try await withLoggedInServer { server in
                // 1.5 s of local work before the first write, against a 1 s deadline.
                try await server.executeCommand(ProbeCommand(prepareSeconds: 1.5, closesChannelFirst: false))
            }
        }

        @Test("a close the handler never saw fails the command at once")
        func closeMissedByHandlerFailsPromptly() async throws {
            try await withLoggedInServer { server in
                let start = Date()
                do {
                    try await server.executeCommand(ProbeCommand(prepareSeconds: 0, closesChannelFirst: true))
                    Issue.record("the command should have failed")
                } catch IMAPError.connectionFailed {
                    // expected
                }
                #expect(Date().timeIntervalSince(start) < 0.9)
            }
        }

        private func withLoggedInServer(_ body: (SwiftMail.IMAPServer) async throws -> Void) async throws {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("cur"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("new"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let testServer = try IMAPTestServer(maildirURL: maildir)
            try testServer.start()
            try await testServer.run {
                let server = SwiftMail.IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()
                try await server.login(username: "testuser", password: "testpass")
                try await body(server)
                try? await server.disconnect()
            }
        }
    }

    /// NOOP with a 1 s deadline, optional local work before its write, and
    /// optionally a channel closed underneath it.
    private struct ProbeCommand: IMAPTaggedCommand {
        typealias ResultType = Void
        typealias HandlerType = CloseBlindHandler

        let prepareSeconds: Double
        let closesChannelFirst: Bool
        var timeoutSeconds: Int { 1 }

        func toTaggedCommand(tag: String) -> TaggedCommand {
            TaggedCommand(tag: tag, command: .noop)
        }

        func send(on channel: Channel, tag: String) async throws {
            if prepareSeconds > 0 { try await Task.sleep(for: .seconds(prepareSeconds)) }
            if closesChannelFirst { try await channel.close() }
            let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(toTaggedCommand(tag: tag)))
            channel.writeAndFlush(wrapped, promise: nil)
        }
    }

    /// Stands in for a handler installed after `channelInactive` was delivered.
    private final class CloseBlindHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {
        override func channelInactive(context: ChannelHandlerContext) {
            context.fireChannelInactive()
        }
    }
#endif
