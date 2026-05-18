// EmailMessageConversionTests+MessageFromEmail.swift
// Tests for converting an `Email` into a `Message` ready for IMAP append / SMTP send.

import Testing
import Foundation
import SwiftMail

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
