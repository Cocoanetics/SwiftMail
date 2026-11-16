import Foundation
import Testing
@testable import SwiftMail

#if os(macOS)
    /// UIDNEXT and UIDVALIDITY are base RFC 3501 STATUS data items (§6.3.10), so every
    /// IMAP4rev1 server supports them; they must not depend on an extension such as UIDPLUS.
    @Suite("STATUS base data items", .serialized, .timeLimit(.minutes(1)))
    struct MailboxStatusBaseItemsTests {
        @Test(
            "STATUS requests and reports UIDNEXT and UIDVALIDITY with or without UIDPLUS",
            arguments: [
                ["IMAP4rev1", "AUTH=PLAIN"],
                ["IMAP4rev1", "AUTH=PLAIN", "UIDPLUS"]
            ]
        )
        func statusCarriesUIDNextAndUIDValidity(capabilities: [String]) async throws {
            try await withServer(capabilities: capabilities) { server, testServer in
                let status = try await server.mailboxStatus("INBOX")
                expectBaseItems(status)

                let named = try await server.connection(named: "status-base-items")
                let namedStatus = try await named.mailboxStatus("INBOX")
                expectBaseItems(namedStatus)

                let statusCommands = testServer.commandLog
                    .map { $0.uppercased() }
                    .filter { $0.contains(" STATUS ") }
                #expect(statusCommands.count == 2)
                for command in statusCommands {
                    for item in ["MESSAGES", "RECENT", "UNSEEN", "UIDNEXT", "UIDVALIDITY"] {
                        #expect(command.contains(item), "\(item) missing from \(command)")
                    }
                }
            }
        }

        private func expectBaseItems(_ status: Mailbox.Status) {
            #expect(status.messageCount == 1)
            #expect(status.uidNext == UID(2))
            #expect(status.uidValidity == UIDValidity(1))
        }

        private func withServer(
            capabilities: [String],
            body: (SwiftMail.IMAPServer, IMAPTestServer) async throws -> Void
        ) async throws {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            let curDir = maildir.appendingPathComponent("cur")
            try FileManager.default.createDirectory(at: curDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let sample = """
            From: Sender <sender@example.com>\r
            To: Recipient <recipient@example.com>\r
            Subject: Status\r
            Date: Wed, 01 Jan 2020 00:00:00 +0000\r
            Message-ID: <status@example.com>\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            Body.\r
            """
            try #require(sample.data(using: .utf8)).write(to: curDir.appendingPathComponent("1.eml"))

            let testServer = try IMAPTestServer(
                username: "u", password: "p",
                advertisedCapabilities: capabilities,
                maildirURL: maildir)
            try testServer.start()
            try await testServer.run {
                let server = SwiftMail.IMAPServer(
                    host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()
                try await server.login(username: "u", password: "p")
                try await body(server, testServer)
                try await server.disconnect()
            }
        }
    }
#endif
