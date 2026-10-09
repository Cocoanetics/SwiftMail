import Foundation
import Testing
@testable import SwiftMail

#if os(macOS)
    @Suite("Long Response Line", .serialized, .timeLimit(.minutes(1)))
    struct LongResponseLineTests {
        /// NIOIMAP 0.4.0 capped a response line it had not finished decoding at 8 KiB, whatever
        /// `responseBufferLimit` said, so one long FETCH line failed with `PayloadTooLargeError`.
        /// Real servers send such lines for the BODYSTRUCTURE of a message with dozens of
        /// attachments; here a long subject makes the ENVELOPE exceed the old cap instead.
        @Test("A FETCH response line longer than 8 KiB parses")
        func fetchResponseLineLongerThanEightKiBParses() async throws {
            let subject = String(repeating: "Long subject ", count: 1_000)
            #expect(subject.utf8.count > 8_192)

            let sampleMessage = Data(("""
            From: Test Sender <sender@example.com>\r
            To: Test Recipient <recipient@example.com>\r
            Subject: \(subject)\r
            Date: Thu, 01 Jan 2026 00:00:00 +0000\r
            Message-ID: <long-line@example.com>\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            Hello.\r
            """).utf8)

            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            let curDir = maildir.appendingPathComponent("cur")
            let newDir = maildir.appendingPathComponent("new")

            try FileManager.default.createDirectory(at: curDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            try sampleMessage.write(to: curDir.appendingPathComponent("1.eml"))

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

                try await server.login(username: "testuser", password: "testpass")
                _ = try await server.selectMailbox("INBOX")

                let info = try await server.fetchMessageInfo(for: UID(1))
                #expect(info?.subject == subject.trimmingCharacters(in: .whitespaces))

                try await server.disconnect()
            }
        }
    }
#endif
