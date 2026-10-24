import Foundation
import Testing
@testable import SwiftMail

/// Every header field written into SMTP content must stay the field it was
/// written as: a line break that does not fold it, or a name that is not a
/// field name, could start a new field, such as a Bcc field every recipient sees.
@Suite("Additional header line breaks", .serialized, .timeLimit(.minutes(1)))
struct AdditionalHeaderLineBreakTests {
    private static let blind = "hidden@example.com"

    @Test("an SMTP send refuses an additional header with a line break that is not a fold", arguments: [
        ["X-Note": "note\rBcc: \(blind)"],
        ["X-Note": "note\nBcc: \(blind)"],
        ["X-Note": "note\r\nBcc: \(blind)"],
        ["X-Note": "note\r\nX-Injected: yes"],
        ["X-Note": "note\r\n \nBcc: \(blind)"],
        ["X-Note": "note\r\n"],
        ["X-Note\r\nBcc": blind]
    ])
    func refusesUnfoldedLineBreak(headers: [String: String]) {
        var email = BccHeaderTests.email
        email.additionalHeaders = headers
        #expect(throws: SMTPError.self) { try SMTPServer.prepareEmailForSend(email, capabilities: []) }
    }

    @Test("an SMTP send keeps folded additional headers byte for byte")
    func keepsFoldedAdditionalHeaders() throws {
        var email = BccHeaderTests.email
        email.additionalHeaders = [
            "References": "<a@example.com>\r\n <b@example.com>",
            "X-Note": "first\r\n\tsecond"
        ]
        let prepared = try SMTPServer.prepareEmailForSend(email, capabilities: [])
        let content = String(bytes: prepared.contentData, encoding: .utf8) ?? ""
        #expect(content.contains("\r\nReferences: <a@example.com>\r\n <b@example.com>\r\n"))
        #expect(content.contains("\r\nX-Note: first\r\n\tsecond\r\n"))
    }

    @Test("an SMTP send refuses an additional header name that is not a header field name", arguments: [
        "Bcc:\(blind),X-Pad", "X Note", "", "X-N\u{F6}te"
    ])
    func refusesInvalidFieldName(name: String) {
        var email = BccHeaderTests.email
        email.additionalHeaders = [name: "p"]
        #expect(throws: SMTPError.self) { try SMTPServer.prepareEmailForSend(email, capabilities: []) }
    }

    @Test("an SMTP send refuses a Message-ID with a line break", arguments: [
        "x\r\nBcc: \(blind)\r\nX-Pad: p", "x\rBcc: \(blind)", "x\nBcc: \(blind)"
    ])
    func refusesLineBreakInMessageID(localPart: String) {
        var email = BccHeaderTests.email
        email.messageID = MessageID(localPart: localPart, domain: "example.com")
        #expect(throws: SMTPError.self) { try SMTPServer.prepareEmailForSend(email, capabilities: []) }
    }

    /// With no Message-ID given, the generated one takes the sender's domain.
    @Test("an SMTP send refuses a sender address whose domain has a line break")
    func refusesLineBreakInSenderDomain() {
        var email = BccHeaderTests.email
        email.sender = EmailAddress(address: "sender@example.com\r\nX-Injected: yes")
        #expect(email.messageID == nil)
        #expect(throws: SMTPError.self) { try SMTPServer.prepareEmailForSend(email, capabilities: []) }
    }

    /// A draft or Sent copy appended over IMAP gets the same check: a field it
    /// stored would reach every recipient when that draft is sent.
    @Test("a copy kept over IMAP refuses a header field an SMTP send refuses", arguments: [
        ["X-Note": "note\rBcc: \(blind)"],
        ["X-Note": "note\nReply-To: \(blind)"],
        ["X-Note": "note\r\nBcc: \(blind)"],
        ["Bcc": blind],
        ["X Note": "p"]
    ])
    func keptCopyRefusesUnsafeHeader(headers: [String: String]) {
        var email = BccHeaderTests.email
        email.additionalHeaders = headers
        #expect(throws: IMAPError.self) { try email.keptCopyContent(use8BitMIME: true) }
    }

    @Test("a copy kept over IMAP refuses a Message-ID or sender domain with a line break")
    func keptCopyRefusesLineBreakInMessageID() {
        var email = BccHeaderTests.email
        email.messageID = MessageID(localPart: "id", domain: "example.com\rX-Injected: yes")
        #expect(throws: IMAPError.self) { try email.keptCopyContent(use8BitMIME: true) }
        var other = BccHeaderTests.email
        other.sender = EmailAddress(address: "sender@example.com\r\nX-Injected: yes")
        #expect(throws: IMAPError.self) { try other.keptCopyContent(use8BitMIME: true) }
    }

    @Test("a copy kept over IMAP keeps its own Bcc header and folded fields")
    func keptCopyKeepsBccAndFolds() throws {
        var email = BccHeaderTests.email
        email.additionalHeaders = ["References": "<a@example.com>\r\n <b@example.com>"]
        let kept = try email.keptCopyContent(use8BitMIME: true)
        let bcc = email.bccRecipients.map { $0.headerString() }.joined(separator: ", ")
        #expect(BccHeaderTests.fields("Bcc", in: kept) == [bcc])
        #expect(kept.contains("\r\nReferences: <a@example.com>\r\n <b@example.com>\r\n"))
    }

    private static func storedDraft(_ lines: [String]) -> Data {
        let all = ["From: sender@example.com", "To: to@example.com"] + lines + ["", "Body."]
        return Data(all.joined(separator: "\r\n").utf8)
    }

    /// Whether a send threw, and what the SMTP server received.
    private struct Delivery {
        let refused: Bool
        let recipients: [String]
        let content: String
    }

    private static func send(_ email: Email) async throws -> Delivery {
        let smtp = SMTPCaptureServer()
        try await smtp.start()
        let client = SMTPServer(host: "127.0.0.1", port: smtp.port, transportSecurity: .plainText)
        try await client.connect()
        var refused = false
        do { _ = try await client.sendEmail(email) } catch is SMTPError { refused = true }
        try await client.disconnect()
        try await smtp.stop()
        return Delivery(
            refused: refused,
            recipients: smtp.recipients.sorted(),
            content: String(bytes: smtp.content, encoding: .utf8) ?? ""
        )
    }

    @Test("a stored draft whose header holds a lone carriage return is refused and nothing is sent")
    func convertedDraftWithLoneCRIsRefused() async throws {
        let email = try Email(message: Message(emlData: Self.storedDraft([
            "Bcc: \(Self.blind)", "Subject: Stored draft", "X-Note: note\rBcc: \(Self.blind)"
        ])))
        #expect(email.bccRecipients.map(\.address) == [Self.blind])
        #expect(email.additionalHeaders?["x-note"]?.contains("\r") == true)

        let result = try await Self.send(email)
        #expect(result.refused)
        #expect(result.recipients.isEmpty)
        #expect(result.content.isEmpty)
    }

    /// The lone carriage return hides the draft's Bcc line inside its Message-ID,
    /// so the BCC recipient would get nothing while the delivered Message-Id
    /// line names them to any reader that ends a line at a carriage return.
    @Test("a stored draft whose Message-ID holds a lone carriage return is refused and nothing is sent")
    func convertedDraftWithLoneCRInMessageIDIsRefused() async throws {
        let email = try Email(message: Message(emlData: Self.storedDraft([
            "Subject: Stored draft", "Message-ID: <x@example.com>\rBcc: \(Self.blind)"
        ])))
        #expect(email.bccRecipients.isEmpty)
        #expect(email.messageID?.description.contains("\r") == true)

        let result = try await Self.send(email)
        #expect(result.refused)
        #expect(result.recipients.isEmpty)
        #expect(result.content.isEmpty)
    }

    @Test("an ordinary stored draft reaches every recipient and names no BCC recipient")
    func convertedOrdinaryDraftIsSent() async throws {
        let email = try Email(message: Message(emlData: Self.storedDraft([
            "Bcc: \(Self.blind)", "Subject: Stored draft", "X-Note: note"
        ])))

        let result = try await Self.send(email)
        #expect(!result.refused)
        #expect(result.recipients == [Self.blind, "to@example.com"])
        #expect(result.content.contains("\r\nx-note: note\r\n"))
        #expect(result.content.contains("Body."))
        #expect(!result.content.contains(Self.blind))
    }
}
