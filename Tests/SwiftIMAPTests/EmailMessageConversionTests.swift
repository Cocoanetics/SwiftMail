// EmailMessageConversionTests.swift
// Tests for bidirectional Message ↔ Email conversion

import Testing
import Foundation
import SwiftMail

// MARK: - Helpers

private func makeMessage(
    from: String? = "Alice <alice@example.com>",
    to: [String] = ["bob@example.com"],
    cc: [String] = [],
    bcc: [String] = [],
    subject: String? = "Hello",
    messageId: MessageID? = nil,
    additionalFields: [String: String]? = nil,
    parts: [MessagePart] = []
) -> Message {
    let header = MessageInfo(
        sequenceNumber: SequenceNumber(1),
        uid: UID(1),
        subject: subject,
        from: from,
        to: to,
        cc: cc,
        bcc: bcc,
        messageId: messageId,
        additionalFields: additionalFields
    )
    return Message(header: header, parts: parts)
}

private func textPart(_ body: String, section: String = "1") -> MessagePart {
    MessagePart(
        sectionString: section,
        contentType: "text/plain",
        disposition: nil,
        encoding: "7bit",
        data: body.data(using: .utf8)
    )
}

private func htmlPart(_ body: String, section: String = "2") -> MessagePart {
    MessagePart(
        sectionString: section,
        contentType: "text/html",
        disposition: nil,
        encoding: "7bit",
        data: body.data(using: .utf8)
    )
}

// MARK: - Email(message:) tests

@Test
func testEmailFromMessage_simpleTextRoundTrip() throws {
    let message = makeMessage(
        from: "Alice <alice@example.com>",
        to: ["Bob <bob@example.com>"],
        cc: ["Carol <carol@example.com>"],
        bcc: ["Dave <dave@example.com>"],
        subject: "Test Subject",
        parts: [textPart("Hello, world!")]
    )

    let email = try Email(message: message)

    #expect(email.sender.address == "alice@example.com")
    #expect(email.sender.name == "Alice")
    #expect(email.recipients.count == 1)
    #expect(email.recipients[0].address == "bob@example.com")
    #expect(email.ccRecipients.count == 1)
    #expect(email.ccRecipients[0].address == "carol@example.com")
    #expect(email.bccRecipients.count == 1)
    #expect(email.bccRecipients[0].address == "dave@example.com")
    #expect(email.subject == "Test Subject")
    #expect(email.textBody == "Hello, world!")
    #expect(email.htmlBody == nil)
    #expect(email.attachments == nil)
}

@Test
func testEmailFromMessage_withAttachments() throws {
    let rawData = Data([0x01, 0x02, 0x03, 0x04, 0x05])
    let base64Encoded = rawData.base64EncodedData()

    let attachmentPart = MessagePart(
        sectionString: "2",
        contentType: "application/octet-stream",
        disposition: "attachment",
        encoding: "base64",
        filename: "test.bin",
        contentId: nil,
        data: base64Encoded
    )

    let message = makeMessage(
        parts: [textPart("Body text"), attachmentPart]
    )

    let email = try Email(message: message)

    #expect(email.textBody == "Body text")
    #expect(email.attachments?.count == 1)
    let att = try #require(email.attachments?.first)
    #expect(att.filename == "test.bin")
    #expect(att.mimeType == "application/octet-stream")
    #expect(att.data == rawData)
    #expect(att.isInline == false)
    #expect(att.contentID == nil)
}

@Test
func testEmailFromMessage_withCIDInlineImages() throws {
    let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0])
    let base64Encoded = imageData.base64EncodedData()

    let cidPart = MessagePart(
        sectionString: "2",
        contentType: "image/jpeg",
        disposition: "inline",
        encoding: "base64",
        filename: "photo.jpg",
        contentId: "<photo001@example.com>",
        data: base64Encoded
    )

    let message = makeMessage(
        parts: [textPart("See photo"), cidPart]
    )

    let email = try Email(message: message)

    #expect(email.attachments?.count == 1)
    let att = try #require(email.attachments?.first)
    #expect(att.contentID == "<photo001@example.com>")
    #expect(att.isInline == true)
    #expect(att.data == imageData)
}

@Test
func testEmailFromMessage_throwsWhenFromIsNil() {
    let message = makeMessage(from: nil)

    #expect(throws: ConversionError.missingSender) {
        try Email(message: message)
    }
}

@Test
func testEmailFromMessage_throwsWhenFromIsUnparseable() {
    let message = makeMessage(from: "not-a-valid-email-address")

    #expect(throws: (any Error).self) {
        try Email(message: message)
    }
}

@Test
func testEmailFromMessage_preservesAdditionalHeaders() throws {
    let fields: [String: String] = [
        "X-Custom-Header": "custom-value",
        "X-Priority": "1",
        // Standard headers that should be skipped:
        "Subject": "should be skipped",
        "From": "should be skipped",
        "To": "should be skipped",
        "Cc": "should be skipped",
        "Bcc": "should be skipped",
        "Message-ID": "should be skipped",
        "References": "should be skipped",
        "In-Reply-To": "should be skipped",
        "Date": "should be skipped"
    ]
    let message = makeMessage(
        additionalFields: fields,
        parts: [textPart("body")]
    )

    let email = try Email(message: message)

    let headers = try #require(email.additionalHeaders)
    #expect(headers["X-Custom-Header"] == "custom-value")
    #expect(headers["X-Priority"] == "1")
    // Standard headers must not appear
    #expect(headers["Subject"] == nil)
    #expect(headers["From"] == nil)
    #expect(headers["To"] == nil)
    #expect(headers["Message-ID"] == nil)
    #expect(headers["Date"] == nil)
}

@Test
func testEmailFromMessage_preservesMessageID() throws {
    let msgId = MessageID(localPart: "abc123", domain: "example.com")
    let message = makeMessage(
        messageId: msgId,
        parts: [textPart("body")]
    )

    let email = try Email(message: message)
    #expect(email.messageID == msgId)
}

@Test
func testEmailFromMessage_bothBodyParts() throws {
    let message = makeMessage(
        parts: [
            textPart("Plain text body", section: "1"),
            htmlPart("<b>HTML body</b>", section: "2")
        ]
    )

    let email = try Email(message: message)

    #expect(email.textBody == "Plain text body")
    #expect(email.htmlBody == "<b>HTML body</b>")
}

// MARK: - Message(email:) tests

@Test
func testMessageFromEmail_simpleRoundTrip() {
    let sender = EmailAddress(name: "Alice", address: "alice@example.com")
    let recipient = EmailAddress(name: "Bob", address: "bob@example.com")
    let email = Email(
        sender: sender,
        recipients: [recipient],
        subject: "Test Subject",
        textBody: "Hello from email"
    )

    let message = Message(email: email)

    #expect(message.subject == "Test Subject")
    #expect(message.from == "Alice <alice@example.com>")
    #expect(message.to == ["Bob <bob@example.com>"])
    #expect(message.textBody == "Hello from email")
    #expect(message.htmlBody == nil)
}

@Test
func testMessageFromEmail_withCCAndBCC() {
    let sender = EmailAddress(address: "alice@example.com")
    let to = EmailAddress(address: "bob@example.com")
    let cc = EmailAddress(address: "carol@example.com")
    let bcc = EmailAddress(address: "dave@example.com")
    let email = Email(
        sender: sender,
        recipients: [to],
        ccRecipients: [cc],
        bccRecipients: [bcc],
        subject: "Multi-recipient",
        textBody: "body"
    )

    let message = Message(email: email)

    #expect(message.to == ["bob@example.com"])
    #expect(message.cc == ["carol@example.com"])
    #expect(message.bcc == ["dave@example.com"])
}

@Test
func testMessageFromEmail_withHTMLBody() {
    let sender = EmailAddress(address: "alice@example.com")
    let email = Email(
        sender: sender,
        recipients: [EmailAddress(address: "bob@example.com")],
        subject: "HTML Email",
        textBody: "Plain text",
        htmlBody: "<p>HTML content</p>"
    )

    let message = Message(email: email)

    // text/plain part at section 1, text/html at section 2
    #expect(message.parts.count == 2)
    #expect(message.parts[0].contentType == "text/plain")
    #expect(message.parts[1].contentType == "text/html")
    #expect(message.htmlBody == "<p>HTML content</p>")
}

@Test
func testMessageFromEmail_withAttachments() {
    let attachmentData = Data([0xAA, 0xBB, 0xCC, 0xDD])
    let att = Attachment(
        filename: "file.dat",
        mimeType: "application/octet-stream",
        data: attachmentData,
        isInline: false
    )
    let sender = EmailAddress(address: "alice@example.com")
    let email = Email(
        sender: sender,
        recipients: [EmailAddress(address: "bob@example.com")],
        subject: "With Attachment",
        textBody: "See attached",
        attachments: [att]
    )

    let message = Message(email: email)

    // Should have text part + attachment part
    #expect(message.parts.count == 2)
    let attPart = message.parts[1]
    #expect(attPart.contentType == "application/octet-stream")
    #expect(attPart.disposition == "attachment")
    #expect(attPart.filename == "file.dat")
    #expect(attPart.data == attachmentData)
    #expect(attPart.encoding == nil)
}

@Test
func testMessageFromEmail_inlineAttachment() {
    let imageData = Data([0x89, 0x50, 0x4E, 0x47])
    let att = Attachment(
        filename: "image.png",
        mimeType: "image/png",
        data: imageData,
        contentID: "<img001@example.com>",
        isInline: true
    )
    let sender = EmailAddress(address: "alice@example.com")
    let email = Email(
        sender: sender,
        recipients: [EmailAddress(address: "bob@example.com")],
        subject: "Inline Image",
        textBody: "",
        htmlBody: "<img src='cid:img001@example.com'>",
        attachments: [att]
    )

    let message = Message(email: email)

    let inlinePart = message.parts.first { $0.contentId != nil }
    #expect(inlinePart != nil)
    #expect(inlinePart?.disposition == "inline")
    #expect(inlinePart?.contentId == "<img001@example.com>")
    #expect(inlinePart?.data == imageData)
}

@Test
func testMessageFromEmail_preservesMessageID() {
    let msgId = MessageID(localPart: "test123", domain: "mail.example.com")
    let sender = EmailAddress(address: "alice@example.com")
    var email = Email(
        sender: sender,
        recipients: [EmailAddress(address: "bob@example.com")],
        subject: "ID Test",
        textBody: "body"
    )
    email.messageID = msgId

    let message = Message(email: email)

    #expect(message.header.messageId == msgId)
}

@Test
func testMessageFromEmail_additionalHeaders() {
    let sender = EmailAddress(address: "alice@example.com")
    var email = Email(
        sender: sender,
        recipients: [EmailAddress(address: "bob@example.com")],
        subject: "Custom Headers",
        textBody: "body"
    )
    email.additionalHeaders = ["X-Custom": "value123"]

    let message = Message(email: email)

    #expect(message.header.additionalFields?["X-Custom"] == "value123")
}

// MARK: - Bidirectional round-trip

@Test
func testBidirectionalRoundTrip_emailToMessageToEmail() throws {
    let sender = EmailAddress(name: "Alice", address: "alice@example.com")
    let recipient = EmailAddress(name: "Bob", address: "bob@example.com")
    let msgId = MessageID(localPart: "roundtrip01", domain: "example.com")
    var original = Email(
        sender: sender,
        recipients: [recipient],
        ccRecipients: [EmailAddress(address: "carol@example.com")],
        subject: "Round-trip Test",
        textBody: "Round-trip body",
        htmlBody: "<p>HTML round-trip</p>"
    )
    original.messageID = msgId

    let message = Message(email: original)
    let restored = try Email(message: message)

    #expect(restored.sender.address == "alice@example.com")
    #expect(restored.sender.name == "Alice")
    #expect(restored.recipients.count == 1)
    #expect(restored.recipients[0].address == "bob@example.com")
    #expect(restored.ccRecipients.count == 1)
    #expect(restored.ccRecipients[0].address == "carol@example.com")
    #expect(restored.subject == "Round-trip Test")
    #expect(restored.textBody == "Round-trip body")
    #expect(restored.htmlBody == "<p>HTML round-trip</p>")
    #expect(restored.messageID == msgId)
}
