import Foundation
import Testing
@testable import SwiftMail

/// A copy the sender keeps (a draft, a Sent copy) names its BCC recipients; a
/// message handed to SMTP never does (RFC 5322 section 3.6.3).
@Suite("Bcc header")
struct BccHeaderTests {
    static let email = Email(
        sender: EmailAddress(address: "sender@example.com"),
        recipients: [EmailAddress(address: "to@example.com")],
        ccRecipients: [EmailAddress(address: "cc@example.com")],
        bccRecipients: [
            EmailAddress(name: "Jörg Hidden", address: "hidden@example.com"),
            EmailAddress(address: "second@example.com")
        ],
        subject: "Bcc test",
        textBody: "Body text."
    )

    private static func headerSection(_ content: String) -> String {
        String(content[..<(content.range(of: "\r\n\r\n")?.lowerBound ?? content.endIndex)])
    }

    /// The unfolded body of every header field named `name` (any case), in order.
    /// Whether `error` is the permanent refusal of an argument the caller wrote.
    static func isInvalidArgument(_ error: IMAPError?) -> Bool {
        guard case .invalidArgument = error else { return false }
        return true
    }

    static func fields(_ name: String, in content: String) -> [String] {
        let unfolded = headerSection(content).replacingOccurrences(of: "\r\n ", with: " ")
            .replacingOccurrences(of: "\r\n\t", with: " ")
        let prefix = name.lowercased() + ":"
        return unfolded.components(separatedBy: "\r\n")
            .filter { $0.lowercased().hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
    }

    /// A kept copy names each recipient only in the field it was given in: one
    /// field per role, so a BCC address never shows where others can see it.
    static func expectRoles(in content: String, to: [EmailAddress], cc: [EmailAddress], bcc: [EmailAddress]) {
        for (name, addresses) in [("To", to), ("Cc", cc), ("Bcc", bcc)] {
            let expected = addresses.isEmpty ? [] : [addresses.map { $0.headerString() }.joined(separator: ", ")]
            #expect(fields(name, in: content) == expected, "\(name)")
        }
    }

    /// Goes through the content SMTPServer actually sends, with and without
    /// 8BITMIME, so a change anywhere on that path is caught.
    @Test("content prepared for an SMTP send names no BCC recipient", arguments: [[String](), ["8BITMIME"]])
    func sentContentHasNoBcc(capabilities: [String]) throws {
        let prepared = try SMTPServer.prepareEmailForSend(Self.email, capabilities: capabilities)
        let content = String(bytes: prepared.contentData, encoding: .utf8) ?? ""
        #expect(content.contains("Body text."))
        #expect(!content.contains("hidden@example.com"))
        #expect(!content.contains("second@example.com"))
        #expect(!Self.headerSection(content).lowercased().contains("bcc:"))
    }

    @Test("content built for a kept copy names every BCC recipient in one Bcc header")
    func keptContentNamesBcc() throws {
        let kept = Self.email.constructContent(includeBccHeader: true)
        let email = Self.email
        Self.expectRoles(in: kept, to: email.recipients, cc: email.ccRecipients, bcc: email.bccRecipients)
        let header = Self.headerSection(kept)
        let line = try #require(header.components(separatedBy: "\r\n").first { $0.hasPrefix("Bcc: ") })
        let expected = Self.email.bccRecipients.map { $0.headerString() }.joined(separator: ", ")
        #expect(line == "Bcc: \(expected)")
        // The display name is not ASCII, so it travels RFC 2047-encoded.
        #expect(!line.contains("ö"))
        #expect(line.contains("<hidden@example.com>"))
        #expect(line.contains("second@example.com"))
    }

    /// A draft may have BCC recipients only, with or without CC.
    @Test("a kept copy with no To recipient names its BCC recipients only in its Bcc header",
          arguments: [1, 2], [false, true])
    func keptCopyWithoutTo(bccCount: Int, withCc: Bool) {
        var email = Self.email
        email.recipients = []
        email.ccRecipients = withCc ? [EmailAddress(address: "cc@example.com")] : []
        email.bccRecipients = Array(Self.email.bccRecipients.prefix(bccCount))
        let kept = email.constructContent(includeBccHeader: true)
        Self.expectRoles(in: kept, to: [], cc: email.ccRecipients, bcc: email.bccRecipients)
        #expect(kept.contains("Body text."))
    }

    @Test("no Bcc header when there are no BCC recipients")
    func noBccRecipientsNoHeader() {
        var email = Self.email
        email.bccRecipients = []
        #expect(!Self.headerSection(email.constructContent(includeBccHeader: true)).lowercased().contains("bcc:"))
    }

    /// `constructContent()` is documented as ready for SMTP, so by default it
    /// names no BCC recipient; only a kept copy asks for the Bcc header.
    @Test("content built with the defaults names no BCC recipient", arguments: [false, true])
    func defaultContentHasNoBcc(use8BitMIME: Bool) {
        let content = Self.email.constructContent(use8BitMIME: use8BitMIME)
        #expect(Self.fields("To", in: content) == ["to@example.com"])
        #expect(Self.fields("Cc", in: content) == ["cc@example.com"])
        #expect(!content.contains("hidden@example.com"))
        #expect(!content.contains("second@example.com"))
        #expect(!Self.headerSection(content).lowercased().contains("bcc:"))
    }

    // MARK: - Blind-copy fields in additionalHeaders (SMTP send)

    @Test("an SMTP send refuses a blind-copy field given as an additional header",
          arguments: ["Bcc", "bcc", "Resent-Bcc", " RESENT-BCC "])
    func sendRefusesBlindAdditionalHeader(name: String) {
        var email = Self.email
        email.additionalHeaders = [name: "extra@example.com"]
        #expect(throws: SMTPError.self) { try SMTPServer.prepareEmailForSend(email, capabilities: []) }
    }

    @Test("an SMTP send keeps other additional headers")
    func sendKeepsOtherAdditionalHeaders() throws {
        var email = Self.email
        email.additionalHeaders = ["X-Bcc-Note": "n", "Resent-To": "resent@example.com"]
        let prepared = try SMTPServer.prepareEmailForSend(email, capabilities: [])
        let content = String(bytes: prepared.contentData, encoding: .utf8) ?? ""
        #expect(Self.fields("X-Bcc-Note", in: content) == ["n"])
        #expect(Self.fields("Resent-To", in: content) == ["resent@example.com"])
        #expect(!content.contains("hidden@example.com"))
    }
}

#if os(macOS)
    @Suite("Bcc header over IMAP and SMTP", .serialized, .timeLimit(.minutes(1)))
    struct BccAppendTests {
        @Test("a message appended over IMAP names its BCC recipients")
        func appendWritesBcc() async throws {
            let appended = try await Self.appendedMessage { server in
                let email = Email(
                    sender: EmailAddress(address: "sender@example.com"),
                    recipients: [EmailAddress(address: "to@example.com")],
                    bccRecipients: [EmailAddress(name: "Hidden", address: "hidden@example.com")],
                    subject: "Copy with Bcc",
                    textBody: "Copy body."
                )
                try await server.append(email: email, to: "Sent", flags: [.seen])
            }
            let stored = String(bytes: appended, encoding: .utf8) ?? ""
            #expect(BccHeaderTests.fields("To", in: stored) == ["to@example.com"])
            #expect(BccHeaderTests.fields("Cc", in: stored).isEmpty)
            #expect(BccHeaderTests.fields("Bcc", in: stored) == ["Hidden <hidden@example.com>"])
            #expect(stored.contains("Copy body."))
        }

        @Test("a draft created over IMAP names its BCC recipients")
        func createDraftWritesBcc() async throws {
            let appended = try await Self.appendedMessage { server in
                let email = Email(
                    sender: EmailAddress(address: "sender@example.com"),
                    recipients: [EmailAddress(address: "to@example.com")],
                    bccRecipients: [EmailAddress(name: "Hidden", address: "hidden@example.com")],
                    subject: "Draft with Bcc",
                    textBody: "Draft body."
                )
                try await server.createDraft(from: email, in: "Drafts")
            }
            let stored = String(bytes: appended, encoding: .utf8) ?? ""
            #expect(BccHeaderTests.fields("To", in: stored) == ["to@example.com"])
            #expect(BccHeaderTests.fields("Cc", in: stored).isEmpty)
            #expect(BccHeaderTests.fields("Bcc", in: stored) == ["Hidden <hidden@example.com>"])
            #expect(stored.contains("Draft body."))
        }

        /// A message copied with `Email(message:)` keeps a lone carriage return
        /// in a header value; stored as it was, it would add a Bcc field that
        /// a later send of the draft delivers to.
        @Test("createDraft refuses a copied message whose header would add a field, and appends nothing")
        func createDraftRefusesInjectedField() async throws {
            let eml = "From: sender@example.com\r\nTo: to@example.com\r\nSubject: Copied\r\n"
                + "X-Note: note\rBcc: attacker@example.com\r\n\r\nBody.\r\n"
            let email = try Email(message: Message(emlData: Data(eml.utf8)))
            #expect(email.bccRecipients.isEmpty)
            let testServer = try await Self.runTestServer { server in
                await #expect(throws: IMAPError.self) {
                    try await server.createDraft(from: email, in: "Drafts")
                }
            }
            #expect(testServer.appendedMessages.isEmpty)
        }

        @Test("append and createDraft refuse an unsafe header field and append nothing", arguments: [
            ["X-Note": "note\r\n\r\n \tcontinued"],
            ["X-Note": "note\rX-Injected: yes"],
            ["Bcc": "extra@example.com"],
            ["X Note": "value"]
        ], [false, true])
        func keptCopyRefusesUnsafeHeader(headers: [String: String], createDraft: Bool) async throws {
            var email = BccHeaderTests.email
            email.additionalHeaders = headers
            let testServer = try await Self.runTestServer { server in
                let error = await #expect(throws: IMAPError.self) {
                    if createDraft {
                        _ = try await server.createDraft(from: email, in: "Drafts")
                    } else {
                        _ = try await server.append(email: email, to: "Sent", flags: [.seen])
                    }
                }
                #expect(BccHeaderTests.isInvalidArgument(error))
                // The same session stores a valid copy.
                _ = try await server.append(email: BccHeaderTests.email, to: "Sent", flags: [.seen])
            }
            #expect(testServer.appendedMessages.count == 1)
            let stored = String(bytes: testServer.appendedMessages.first ?? Data(), encoding: .utf8) ?? ""
            #expect(stored.contains("Body text."))
            #expect(!stored.contains("continued") && !stored.contains("X-Injected") && !stored.contains("extra@"))
        }

        @Test("sendEmail delivers to BCC recipients without naming them")
        func sendEmailKeepsBccOutOfTheDeliveredCopy() async throws {
            let smtp = SMTPCaptureServer()
            try await smtp.start()
            let client = SMTPServer(host: "127.0.0.1", port: smtp.port, transportSecurity: .plainText)
            try await client.connect()
            _ = try await client.sendEmail(BccHeaderTests.email)
            try await client.disconnect()
            try await smtp.stop()

            #expect(smtp.recipients.sorted()
                == ["cc@example.com", "hidden@example.com", "second@example.com", "to@example.com"])
            let delivered = String(bytes: smtp.content, encoding: .utf8) ?? ""
            #expect(delivered.contains("Body text."))
            #expect(!delivered.contains("hidden@example.com"))
            #expect(!delivered.contains("second@example.com"))
        }

        /// Unfolding "\r\n\r\n \t" one fold at a time, dropping each fold's
        /// whitespace, would leave no line break and pass a blank line that ends
        /// the header.
        @Test("sendEmail refuses an unsafe additional header and sends nothing", arguments: [
            ["Resent-Bcc": "resent@example.com"],
            ["X-Note": "note\r\n\r\n \tcontinued"]
        ])
        func sendEmailRefusesUnsafeAdditionalHeader(headers: [String: String]) async throws {
            var email = BccHeaderTests.email
            email.additionalHeaders = headers
            let smtp = SMTPCaptureServer()
            try await smtp.start()
            let client = SMTPServer(host: "127.0.0.1", port: smtp.port, transportSecurity: .plainText)
            try await client.connect()
            await #expect(throws: SMTPError.self) { try await client.sendEmail(email) }
            try await client.disconnect()
            try await smtp.stop()
            #expect(smtp.recipients.isEmpty)
            #expect(smtp.content.isEmpty)
        }

        /// Sending a draft that names BCC recipients delivers to them, sends no
        /// one a copy that names them, and files a Sent copy that does.
        @Test("sendDraft delivers to BCC recipients without naming them, and the Sent copy names them")
        func sendDraftKeepsBccOutOfTheDeliveredCopy() async throws {
            let draft = [
                "From: sender@example.com",
                "To: to@example.com",
                "Bcc: Hidden <hidden@example.com>",
                "Subject: Draft with Bcc",
                "Message-ID: <draft-bcc@example.com>",
                "",
                "Draft body.",
                ""
            ].joined(separator: "\r\n")
            let smtp = SMTPCaptureServer()
            try await smtp.start()
            let testServer = try await Self.runTestServer(seeding: draft) { server in
                let client = SMTPServer(host: "127.0.0.1", port: smtp.port, transportSecurity: .plainText)
                try await client.connect()
                _ = try await server.sendDraft(uid: UID(1), via: client, from: "Drafts", to: "Sent")
                try await client.disconnect()
            }
            try await smtp.stop()
            #expect(testServer.appendedMessages.count == 1)
            let appended = try #require(testServer.appendedMessages.first)

            // The draft is retired only after its Sent copy is stored.
            let commands = testServer.commandLog.map { $0.uppercased() }
            let append = commands.firstIndex { $0.contains(" APPEND ") }
            let store = commands.firstIndex {
                $0.contains(" STORE ") && $0.contains("+FLAGS") && $0.contains("\\DELETED")
            }
            let expunge = commands.firstIndex { $0.contains("EXPUNGE") }
            #expect(append != nil && store != nil && expunge != nil)
            if let append, let store, let expunge {
                #expect(append < store && store < expunge)
            }

            #expect(smtp.recipients.sorted() == ["hidden@example.com", "to@example.com"])
            let delivered = String(bytes: smtp.content, encoding: .utf8) ?? ""
            #expect(delivered.contains("Draft body."))
            #expect(!delivered.contains("hidden@example.com"))
            let sentCopy = (String(bytes: appended, encoding: .utf8) ?? "")
                .components(separatedBy: "\r\n\r\n").first ?? ""
            #expect(sentCopy.components(separatedBy: "\r\n").contains("Bcc: Hidden <hidden@example.com>"))
        }

        /// A draft whose header holds a lone carriage return or a Resent-Bcc
        /// field is refused before anything reaches SMTP, and stays in the
        /// Drafts folder as it was.
        @Test("sendDraft refuses a draft it cannot send without disclosing a blind recipient",
              arguments: ["\rX-Note: odd", "Resent-Bcc: resent@example.com",
                          "Bcc\r\n : leak@example.com", "Bcc\u{0B}: leak@example.com",
                          "X-Note: odd\n"])
        func sendDraftRefusesUnsafeHeader(line: String) async throws {
            let draft = "From: sender@example.com\r\nTo: to@example.com\r\n\(line)\r\n"
                + "Bcc: hidden@example.com\r\nSubject: Draft\r\nMessage-ID: <draft-cr@example.com>\r\n"
                + "\r\nDraft body.\r\n"
            let smtp = SMTPCaptureServer()
            try await smtp.start()
            let testServer = try await Self.runTestServer(seeding: draft) { server in
                let client = SMTPServer(host: "127.0.0.1", port: smtp.port, transportSecurity: .plainText)
                try await client.connect()
                let error = await #expect(throws: IMAPError.self) {
                    try await server.sendDraft(uid: UID(1), via: client, from: "Drafts", to: "Sent")
                }
                #expect(BccHeaderTests.isInvalidArgument(error))
                try await client.disconnect()
            }
            try await smtp.stop()

            #expect(smtp.recipients.isEmpty)
            #expect(smtp.content.isEmpty)
            #expect(testServer.appendedMessages.isEmpty)
            let commands = testServer.commandLog.map { $0.uppercased() }
            #expect(commands.contains { $0.contains("FETCH") })
            #expect(!commands.contains { $0.contains("STORE") || $0.contains("EXPUNGE") })
        }

        /// Runs `body` against an IMAP test server whose one mailbox holds
        /// `seeding` (when given), and returns the one message it APPENDed.
        private static func appendedMessage(
            seeding message: String? = nil,
            _ body: (IMAPServer) async throws -> Void
        ) async throws -> Data {
            let messages = try await runTestServer(seeding: message, body).appendedMessages
            #expect(messages.count == 1)
            return try #require(messages.first)
        }

        /// Runs `body` against an IMAP test server whose one mailbox holds
        /// `seeding` (when given), and returns the stopped server.
        static func runTestServer(
            seeding message: String? = nil,
            _ body: (IMAPServer) async throws -> Void
        ) async throws -> IMAPTestServer {
            try await runTestServer(seeding: message.map { Data($0.utf8) }, body)
        }

        /// Runs `body` against an IMAP test server whose one mailbox holds the
        /// bytes `seeding` (when given), and returns the stopped server.
        static func runTestServer(
            seeding message: Data?,
            _ body: (IMAPServer) async throws -> Void
        ) async throws -> IMAPTestServer {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("cur"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("new"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            if let message {
                try message.write(to: maildir.appendingPathComponent("cur/1.eml"))
            }

            let testServer = try IMAPTestServer(maildirURL: maildir)
            try testServer.start()
            try await testServer.run {
                let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()
                try await server.login(username: "testuser", password: "testpass")
                try await body(server)
                try await server.disconnect()
            }
            return testServer
        }
    }
#endif
