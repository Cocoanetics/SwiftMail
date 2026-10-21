import Foundation
import Testing
@testable import SwiftMail

/// A copy the sender keeps (a Sent copy) names its BCC recipients; a message
/// handed to SMTP never does (RFC 5322 section 3.6.3).
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

    /// A message may have BCC recipients only, with or without CC.
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
}

#if os(macOS)
    @Suite("Bcc header over IMAP", .serialized, .timeLimit(.minutes(1)))
    struct BccAppendTests {
        static let withBcc = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "to@example.com")],
            bccRecipients: [EmailAddress(name: "Hidden", address: "hidden@example.com")],
            subject: "Copy with Bcc",
            textBody: "Copy body."
        )

        @Test("a message appended over IMAP names its BCC recipients")
        func appendWritesBcc() async throws {
            let appended = try await Self.appendedMessage { server in
                try await server.append(email: Self.withBcc, to: "Sent", flags: [.seen])
            }
            let stored = String(bytes: appended, encoding: .utf8) ?? ""
            #expect(BccHeaderTests.fields("To", in: stored) == ["to@example.com"])
            #expect(BccHeaderTests.fields("Cc", in: stored).isEmpty)
            #expect(BccHeaderTests.fields("Bcc", in: stored) == ["Hidden <hidden@example.com>"])
            #expect(stored.contains("Copy body."))
        }

        /// sendDraft sends a draft's stored bytes to every recipient, so a draft
        /// must not name its BCC recipients.
        @Test("a draft created over IMAP names no BCC recipient")
        func createDraftWritesNoBcc() async throws {
            let appended = try await Self.appendedMessage { server in
                try await server.createDraft(from: Self.withBcc, in: "Drafts")
            }
            let stored = String(bytes: appended, encoding: .utf8) ?? ""
            #expect(BccHeaderTests.fields("To", in: stored) == ["to@example.com"])
            #expect(BccHeaderTests.fields("Bcc", in: stored).isEmpty)
            #expect(!stored.contains("hidden@example.com"))
            #expect(stored.contains("Copy body."))
        }

        /// Runs `body` against an IMAP test server with an empty mailbox, and
        /// returns the one message it APPENDed.
        private static func appendedMessage(_ body: (IMAPServer) async throws -> Void) async throws -> Data {
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
                let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()
                try await server.login(username: "testuser", password: "testpass")
                try await body(server)
                try await server.disconnect()
            }
            let messages = testServer.appendedMessages
            #expect(messages.count == 1)
            return try #require(messages.first)
        }
    }
#endif
