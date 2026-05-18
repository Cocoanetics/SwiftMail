// EmailMessageConversionTests.swift
// Tests for converting a parsed `Message` (IMAP fetch result) into an `Email`.

import Testing
import Foundation
import SwiftMail

private typealias Fixtures = EmailMessageConversionFixtures

@Test
func testEmailFromMessage_simpleTextRoundTrip() throws {
    let message = Fixtures.makeMessage(
        from: "Alice <alice@example.com>",
        to: ["Bob <bob@example.com>"],
        cc: ["Carol <carol@example.com>"],
        bcc: ["Dave <dave@example.com>"],
        subject: "Test Subject",
        parts: [Fixtures.textPart("Hello, world!")]
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

    let message = Fixtures.makeMessage(
        parts: [Fixtures.textPart("Body text"), attachmentPart]
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

    let message = Fixtures.makeMessage(
        parts: [Fixtures.textPart("See photo"), cidPart]
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
    let message = Fixtures.makeMessage(from: nil)

    #expect(throws: ConversionError.missingSender) {
        try Email(message: message)
    }
}

@Test
func testEmailFromMessage_throwsWhenFromIsUnparseable() {
    let message = Fixtures.makeMessage(from: "not-a-valid-email-address")

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
    let message = Fixtures.makeMessage(
        additionalFields: fields,
        parts: [Fixtures.textPart("body")]
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
    let message = Fixtures.makeMessage(
        messageId: msgId,
        parts: [Fixtures.textPart("body")]
    )

    let email = try Email(message: message)
    #expect(email.messageID == msgId)
}

@Test
func testEmailFromMessage_bothBodyParts() throws {
    let message = Fixtures.makeMessage(
        parts: [
            Fixtures.textPart("Plain text body", section: "1"),
            Fixtures.htmlPart("<b>HTML body</b>", section: "2")
        ]
    )

    let email = try Email(message: message)

    #expect(email.textBody == "Plain text body")
    #expect(email.htmlBody == "<b>HTML body</b>")
}
