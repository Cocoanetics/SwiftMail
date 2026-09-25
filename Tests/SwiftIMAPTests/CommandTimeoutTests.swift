import Foundation
import Testing
@testable import SwiftMail

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
