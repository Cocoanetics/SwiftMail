import Foundation
import Testing
@testable import SwiftMail

#if os(macOS)
    /// A message stored over IMAP has CRLF line endings only, whatever line endings
    /// and characters its body uses (RFC 3501 §6.3.11 appends an RFC 5322 message).
    struct AppendLineEndingTests {
        @Test(arguments: [
            ("one\ntwo\rthree\r\nfour", "one\r\ntwo\r\nthree\r\nfour"),
            ("one\n\u{301}two\r\u{FE0F}three\r\n\u{1F3FB}four", "one\r\n\u{301}two\r\n\u{FE0F}three\r\n\u{1F3FB}four")
        ])
        func appendedMessageHasOnlyCRLFLineEndings(body: String, storedBody: String) async throws {
            let server = try await BccAppendTests.runTestServer { server in
                let email = Email(
                    sender: EmailAddress(address: "sender@example.com"),
                    recipients: [EmailAddress(address: "to@example.com")],
                    subject: "Line endings",
                    textBody: body
                )
                try await server.append(email: email, to: "Sent", flags: [.seen])
            }
            let messages = server.appendedMessages
            #expect(messages.count == 1)
            guard let stored = messages.first else { return }
            let part = "Content-Transfer-Encoding: 8bit\r\n\r\n" + storedBody + "\r\n"
            #expect(stored.range(of: Data(part.utf8)) != nil, "the stored body is not the body with CRLF line endings")
            Self.expectCRLFOnly(Array(stored))
        }

        /// The Sent copy `sendDraft` files is the draft with CRLF line endings, and
        /// ends in CRLF even when the draft does not.
        @Test
        func sendDraftSentCopyHasOnlyCRLFLineEndings() async throws {
            let header = [
                "From: sender@example.com",
                "To: to@example.com",
                "Subject: Draft line endings",
                "Message-ID: <draft-lines@example.com>",
                "",
                ""
            ].joined(separator: "\r\n")
            let draft = header + "one\n\u{301}two\r\u{FE0F}three\r\n\u{1F3FB}four"
            let smtp = SMTPCaptureServer()
            try await smtp.start()
            let testServer = try await BccAppendTests.runTestServer(seeding: draft) { server in
                let client = SMTPServer(host: "127.0.0.1", port: smtp.port, transportSecurity: .plainText)
                try await client.connect()
                _ = try await server.sendDraft(uid: UID(1), via: client, from: "Drafts", to: "Sent")
                try await client.disconnect()
            }
            try await smtp.stop()
            let messages = testServer.appendedMessages
            #expect(messages.count == 1)
            guard let stored = messages.first else { return }
            let expected = header + "one\r\n\u{301}two\r\n\u{FE0F}three\r\n\u{1F3FB}four\r\n"
            #expect(stored == Data(expected.utf8), "the Sent copy is not the draft with CRLF line endings")
            Self.expectCRLFOnly(Array(stored))
        }

        /// Every LF follows a CR and every CR precedes an LF.
        private static func expectCRLFOnly(_ bytes: [UInt8]) {
            for index in bytes.indices {
                if bytes[index] == 0x0A {
                    #expect(index > 0 && bytes[index - 1] == 0x0D, "LF without CR at octet \(index)")
                }
                if bytes[index] == 0x0D {
                    #expect(index + 1 < bytes.count && bytes[index + 1] == 0x0A, "CR without LF at octet \(index)")
                }
            }
        }
    }
#endif
