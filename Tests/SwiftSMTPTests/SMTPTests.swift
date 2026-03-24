import Foundation
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SMTPTests {
    @Test
    func testPlaceholder() {
        // This is just a placeholder test to ensure the test target can compile
        // Once you implement SwiftSMTP functionality, replace with actual tests
        #expect(Bool(true))
    }
    
    @Test
    func testSMTPServerInit() {
        // Test that we can initialize an SMTPServer
        _ = SMTPServer(host: "smtp.example.com", port: 587)
        // Since there's no API to check properties, just verify it's created
        #expect(Bool(true), "SMTPServer instance created")
    }
    
    @Test
    func testEmailInit() {
        // Test email initialization
        let sender = EmailAddress(name: "Sender", address: "sender@example.com")
        let recipient1 = EmailAddress(address: "recipient1@example.com")
        let recipient2 = EmailAddress(name: "Recipient 2", address: "recipient2@example.com")
        
        let email = Email(
            sender: sender,
            recipients: [recipient1, recipient2],
            subject: "Test Subject",
            textBody: "Test Body"
        )
        
        #expect(email.sender.address == "sender@example.com", "Sender address should match")
        #expect(email.recipients.count == 2, "Should have 2 recipients")
        #expect(email.subject == "Test Subject", "Subject should match")
        #expect(email.textBody == "Test Body", "Text body should match")
    }
    
    @Test
    func testEmailStringInit() {
        // Test the string-based initializer
        let email = Email(
            senderName: "Test Sender",
            senderAddress: "sender@example.com",
            recipientNames: nil,
            recipientAddresses: ["recipient@example.com"],
            subject: "Test Subject",
            textBody: "Test Body"
        )
        
        #expect(email.sender.name == "Test Sender", "Sender name should match")
        #expect(email.sender.address == "sender@example.com", "Sender address should match")
        #expect(email.recipients.count == 1, "Should have 1 recipient")
        #expect(email.recipients[0].address == "recipient@example.com", "Recipient address should match")
    }

    @Test
    func testRequiresSTARTTLSUpgradePolicy() {
        #expect(
            SMTPServer.requiresSTARTTLSUpgrade(
                port: 587,
                useSSL: false,
                capabilities: ["SIZE", "STARTTLS", "AUTH PLAIN"]
            )
        )

        #expect(
            !SMTPServer.requiresSTARTTLSUpgrade(
                port: 587,
                useSSL: false,
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )

        #expect(
            !SMTPServer.requiresSTARTTLSUpgrade(
                port: 465,
                useSSL: true,
                capabilities: ["STARTTLS"]
            )
        )
    }

    @Test
    func testSTARTTLSFailureIsFatalForPort587RegardlessOfHost() {
        #expect(SMTPServer.shouldFailClosedOnSTARTTLSFailure(port: 587, host: "smtp.gmail.com"))
        #expect(SMTPServer.shouldFailClosedOnSTARTTLSFailure(port: 587, host: "smtp.example.com"))

        #expect(!SMTPServer.shouldFailClosedOnSTARTTLSFailure(port: 465, host: "smtp.gmail.com"))
        #expect(!SMTPServer.shouldFailClosedOnSTARTTLSFailure(port: 25, host: "smtp.example.com"))
    }

    @Test
    func testMaximumMessageSizeOctetsParsesSIZECapability() {
        #expect(
            SMTPServer.maximumMessageSizeOctets(
                from: ["PIPELINING", "SIZE 12345678", "AUTH PLAIN"]
            ) == 12_345_678
        )
    }

    @Test
    func testMaximumMessageSizeOctetsIgnoresMalformedSIZECapability() {
        #expect(SMTPServer.maximumMessageSizeOctets(from: ["SIZE nope"]) == nil)
        #expect(SMTPServer.maximumMessageSizeOctets(from: ["SIZE 0"]) == nil)
        #expect(SMTPServer.maximumMessageSizeOctets(from: ["AUTH PLAIN"]) == nil)
    }

    @Test
    func testMailFromCommandFormatsSizeAnd8BitMIMEParameters() throws {
        let plain = try MailFromCommand(senderAddress: "sender@example.com", messageSizeOctets: 4096)
        #expect(plain.toCommandString() == "MAIL FROM:<sender@example.com> SIZE=4096")

        let eightBit = try MailFromCommand(senderAddress: "sender@example.com", use8BitMIME: true)
        #expect(eightBit.toCommandString() == "MAIL FROM:<sender@example.com> BODY=8BITMIME")

        let combined = try MailFromCommand(
            senderAddress: "sender@example.com",
            use8BitMIME: true,
            messageSizeOctets: 4096
        )
        #expect(combined.toCommandString() == "MAIL FROM:<sender@example.com> BODY=8BITMIME SIZE=4096")
    }

    @Test
    func testMessageSizeOctetsTracksGeneratedContentForAttachments() {
        let inlineAttachment = Attachment(
            filename: "inline.png",
            mimeType: "image/png",
            data: Data(repeating: 0x42, count: 1024),
            contentID: "inline-image",
            isInline: true
        )
        let regularAttachment = Attachment(
            filename: "report.pdf",
            mimeType: "application/pdf",
            data: Data(repeating: 0x5A, count: 2048)
        )
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Large",
            textBody: "Hello",
            htmlBody: "<p>Hello<img src=\"cid:inline-image\"></p>",
            attachments: [inlineAttachment, regularAttachment]
        )

        let quotedPrintableSize = email.messageSizeOctets(use8BitMIME: false)
        let eightBitSize = email.messageSizeOctets(use8BitMIME: true)

        #expect(quotedPrintableSize > 0)
        #expect(eightBitSize > 0)
        #expect(quotedPrintableSize == email.constructContent(use8BitMIME: false).utf8.count)
        #expect(eightBitSize == email.constructContent(use8BitMIME: true).utf8.count)
    }

    @Test
    func testPrepareEmailForSendOmitsMailFromSizeWhenServerDoesNotAdvertiseSIZE() throws {
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Hello",
            textBody: "Body"
        )

        let prepared = try SMTPServer.prepareEmailForSend(
            email,
            capabilities: ["PIPELINING", "8BITMIME"]
        )

        #expect(prepared.use8BitMIME)
        #expect(prepared.emailSizeOctets > 0)
        #expect(prepared.mailFromMessageSizeOctets == nil)
    }

    @Test
    func testPrepareEmailForSendUsesMailFromSizeWhenServerAdvertisesSIZE() throws {
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Hello",
            textBody: "Body"
        )

        let prepared = try SMTPServer.prepareEmailForSend(
            email,
            capabilities: ["PIPELINING", "SIZE 999999"]
        )

        #expect(prepared.emailSizeOctets > 0)
        #expect(prepared.mailFromMessageSizeOctets == prepared.emailSizeOctets)
    }

    @Test
    func testPrepareEmailForSendRejectsMessagesExceedingAdvertisedSIZE() {
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Hello",
            textBody: String(repeating: "A", count: 4096)
        )

        #expect(throws: SMTPError.self) {
            try SMTPServer.prepareEmailForSend(
                email,
                capabilities: ["PIPELINING", "SIZE 128"]
            )
        }
    }

    @Test
    func testConstructContentAutoGeneratesMessageId() {
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Test",
            textBody: "Hello"
        )

        let content = email.constructContent()
        #expect(content.contains("Message-Id: <"))
        #expect(content.contains("@example.com>"))
    }

    @Test
    func testConstructContentUsesPresetMessageId() {
        let preset = MessageID(localPart: "my-custom-id", domain: "example.com")
        var email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Test",
            textBody: "Hello"
        )
        email.messageID = preset

        let content = email.constructContent()
        #expect(content.contains("Message-Id: <my-custom-id@example.com>\r\n"))

        // Should NOT contain a second auto-generated Message-Id
        let occurrences = content.components(separatedBy: "Message-Id:").count - 1
        #expect(occurrences == 1)
    }

    @Test
    func testConstructContentStableMessageIdAcrossCalls() {
        let preset = MessageID(localPart: "stable-id", domain: "example.com")
        var email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Test",
            textBody: "Hello"
        )
        email.messageID = preset

        let content1 = email.constructContent()
        let content2 = email.constructContent()

        // With a preset ID, both calls produce the same Message-Id
        #expect(content1.contains("Message-Id: <stable-id@example.com>"))
        #expect(content2.contains("Message-Id: <stable-id@example.com>"))
    }

    @Test
    func testMessageIdPropertyDoesNotAffectAdditionalHeaders() {
        var email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Test",
            textBody: "Hello"
        )
        email.messageID = MessageID(localPart: "preset", domain: "example.com")
        email.additionalHeaders = ["X-Custom": "value"]

        let content = email.constructContent()
        #expect(content.contains("Message-Id: <preset@example.com>"))
        #expect(content.contains("X-Custom: value"))

        // Only one Message-Id header
        let occurrences = content.components(separatedBy: "Message-Id:").count - 1
        #expect(occurrences == 1)
    }

    @Test
    func testMessageIDGenerate() {
        let id = MessageID.generate(domain: "example.com")
        #expect(id.domain == "example.com")
        #expect(!id.localPart.isEmpty)
        #expect(id.description.hasPrefix("<"))
        #expect(id.description.hasSuffix("@example.com>"))
    }

    @Test
    func testMessageIDParseValid() {
        let id = MessageID("<abc-123@example.com>")
        #expect(id != nil)
        #expect(id?.localPart == "abc-123")
        #expect(id?.domain == "example.com")
        #expect(id?.description == "<abc-123@example.com>")
    }

    @Test
    func testMessageIDParseWithoutBrackets() {
        let id = MessageID("abc-123@example.com")
        #expect(id != nil)
        #expect(id?.localPart == "abc-123")
        #expect(id?.domain == "example.com")
    }

    @Test
    func testMessageIDParseInvalid() {
        #expect(MessageID("no-at-sign") == nil)
        #expect(MessageID("@domain.com") == nil)
        #expect(MessageID("local@") == nil)
        #expect(MessageID("") == nil)
    }

    @Test
    func testConstructContentUsesAdditionalHeaderMessageIDExactlyOnce() {
        var email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Hello",
            textBody: "Body"
        )
        email.additionalHeaders = [
            "Message-ID": "<provided@example.com>",
            "X-Test-Header": "present"
        ]

        let content = email.constructContent()
        let messageIDHeaders = content
            .components(separatedBy: "\r\n")
            .filter { $0.lowercased().hasPrefix("message-id:") }

        #expect(messageIDHeaders.count == 1)
        #expect(messageIDHeaders.first == "Message-Id: <provided@example.com>")
        #expect(content.contains("X-Test-Header: present"))
    }

    @Test
    func testConstructContentTreatsAdditionalHeaderMessageIDCaseInsensitively() {
        var email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Hello",
            textBody: "Body"
        )
        email.additionalHeaders = ["message-id": "<lowercase@example.com>"]

        let content = email.constructContent()
        let messageIDHeaders = content
            .components(separatedBy: "\r\n")
            .filter { $0.lowercased().hasPrefix("message-id:") }

        #expect(messageIDHeaders.count == 1)
        #expect(messageIDHeaders.first == "Message-Id: <lowercase@example.com>")
    }

    @Test
    func testConstructContentMessageIDPropertyWinsOverAdditionalHeaderMessageID() {
        var email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Hello",
            textBody: "Body"
        )
        email.messageID = MessageID(localPart: "typed", domain: "example.com")
        email.additionalHeaders = ["Message-ID": "<raw@example.com>"]

        let content = email.constructContent()
        let messageIDHeaders = content
            .components(separatedBy: "\r\n")
            .filter { $0.lowercased().hasPrefix("message-id:") }

        #expect(messageIDHeaders.count == 1)
        #expect(messageIDHeaders.first == "Message-Id: <typed@example.com>")
    }

    @Test
    func testConstructContentPreservesRawAdditionalHeaderMessageIDWhenUnparseable() {
        var email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Hello",
            textBody: "Body"
        )
        email.additionalHeaders = ["Message-ID": "not a valid message id"]

        let content = email.constructContent()
        let messageIDHeaders = content
            .components(separatedBy: "\r\n")
            .filter { $0.lowercased().hasPrefix("message-id:") }

        #expect(messageIDHeaders.count == 1)
        #expect(messageIDHeaders.first == "Message-ID: not a valid message id")
    }

    // MARK: - sendRawMessage validation

    @Test
    func testSendRawMessageRequiresAtLeastOneRecipient() async {
        let server = SMTPServer(host: "smtp.example.com", port: 587)
        let rawMessage = "Subject: Test\r\n\r\nBody".data(using: .utf8)!
        let sender = EmailAddress(address: "sender@example.com")

        await #expect(throws: SMTPError.self) {
            try await server.sendRawMessage(rawMessage, from: sender, to: [])
        }
    }

    @Test
    func testSendRawMessageRequiresConnection() async {
        let server = SMTPServer(host: "smtp.example.com", port: 587)
        let rawMessage = "Subject: Test\r\n\r\nBody".data(using: .utf8)!
        let sender = EmailAddress(address: "sender@example.com")
        let recipient = EmailAddress(address: "recipient@example.com")

        await #expect(throws: SMTPError.self) {
            try await server.sendRawMessage(rawMessage, from: sender, to: [recipient])
        }
    }

    @Test
    func testSendRawMessageRequiresConnectionBeforeValidation() async {
        let server = SMTPServer(host: "smtp.example.com", port: 587)
        // Data with 8-bit content
        let data8Bit = Data([0xFF, 0xFE, 0x00, 0x48, 0x65, 0x6C, 0x6C, 0x6F])
        let sender = EmailAddress(address: "sender@example.com")
        let recipient = EmailAddress(address: "recipient@example.com")

        // Should fail with connectionFailed (checked before 8BITMIME validation)
        do {
            try await server.sendRawMessage(data8Bit, from: sender, to: [recipient])
            Issue.record("Expected SMTPError to be thrown")
        } catch let error as SMTPError {
            // Verify it's a connection error, not an 8BITMIME error
            if case .connectionFailed = error {
                // Expected
            } else {
                Issue.record("Expected connectionFailed, got: \(error)")
            }
        } catch {
            Issue.record("Expected SMTPError, got: \(error)")
        }
    }
    
    @Test
    func testSendRawMessage7BitContentDoesNotRequire8BitMIME() async {
        let server = SMTPServer(host: "smtp.example.com", port: 587)
        // Pure 7-bit ASCII content (all bytes <= 127)
        let data7Bit = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]) // "Hello"
        let sender = EmailAddress(address: "sender@example.com")
        let recipient = EmailAddress(address: "recipient@example.com")

        // Should fail with connectionFailed, NOT an 8BITMIME error
        // (because 7-bit content doesn't require 8BITMIME support)
        do {
            try await server.sendRawMessage(data7Bit, from: sender, to: [recipient])
            Issue.record("Expected SMTPError to be thrown")
        } catch let error as SMTPError {
            if case .connectionFailed = error {
                // Expected - would fail at connection, not 8BITMIME check
            } else {
                Issue.record("Expected connectionFailed for 7-bit content, got: \(error)")
            }
        } catch {
            Issue.record("Expected SMTPError, got: \(error)")
        }
    }

    // MARK: - SMTPError LocalizedError

    @Test
    func testSMTPErrorLocalizedDescriptionReturnsRealMessage() {
        let error: Error = SMTPError.connectionFailed("Connection refused")
        #expect(error.localizedDescription == "SMTP connection failed: Connection refused")
    }

    @Test
    func testSMTPErrorLocalizedDescriptionForAllCases() {
        let cases: [(SMTPError, String)] = [
            (.connectionFailed("timeout"), "SMTP connection failed: timeout"),
            (.invalidResponse("garbled"), "SMTP invalid response: garbled"),
            (.sendFailed("broken pipe"), "SMTP send failed: broken pipe"),
            (.authenticationFailed("bad creds"), "SMTP authentication failed: bad creds"),
            (.commandFailed("550 denied"), "SMTP command failed: 550 denied"),
            (.invalidEmailAddress("bad@"), "SMTP invalid email address: bad@"),
            (.tlsFailed("handshake"), "SMTP TLS failed: handshake"),
            (.messageTooLarge(messageSizeOctets: 100, maximumMessageSizeOctets: 50), "SMTP message too large: 100 bytes exceeds 50 byte limit"),
        ]
        for (error, expected) in cases {
            let asError: Error = error
            #expect(asError.localizedDescription == expected)
        }
    }
}
