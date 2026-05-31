// Splitting this test file was tried but introduced a macOS CI hang;
// see the IMAPTestServer.swift comment for context.
// swiftlint:disable file_length type_body_length

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
                transportMode: SMTPServer.resolveTransportMode(
                    port: 587,
                    transportSecurity: .automatic
                ),
                capabilities: ["SIZE", "STARTTLS", "AUTH PLAIN"]
            )
        )

        #expect(
            !SMTPServer.requiresSTARTTLSUpgrade(
                transportMode: SMTPServer.resolveTransportMode(
                    port: 587,
                    transportSecurity: .automatic
                ),
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )

        #expect(
            !SMTPServer.requiresSTARTTLSUpgrade(
                transportMode: SMTPServer.resolveTransportMode(
                    port: 465,
                    transportSecurity: .automatic
                ),
                capabilities: ["STARTTLS"]
            )
        )
    }

    @Test
    func testMissingSTARTTLSIsFatalForExplicitSTARTTLSPolicy() {
        #expect(
            SMTPServer.requiresMissingSTARTTLSError(
                transportMode: SMTPServer.resolveTransportMode(
                    port: 587,
                    transportSecurity: .startTLS
                ),
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )

        #expect(
            !SMTPServer.requiresMissingSTARTTLSError(
                transportMode: SMTPServer.resolveTransportMode(
                    port: 587,
                    transportSecurity: .automatic
                ),
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )

        #expect(
            !SMTPServer.requiresMissingSTARTTLSError(
                transportMode: SMTPServer.resolveTransportMode(
                    port: 465,
                    transportSecurity: .automatic
                ),
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )

        #expect(
            !SMTPServer.requiresMissingSTARTTLSError(
                transportMode: SMTPServer.resolveTransportMode(
                    port: 25,
                    transportSecurity: .automatic
                ),
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )
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
    func testConstructContentClosesAlternativeBoundaryBeforeRegularAttachment() throws {
        let regularAttachment = Attachment(
            filename: "report.pdf",
            mimeType: "application/pdf",
            data: Data(repeating: 0x5A, count: 16)
        )
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "HTML + regular",
            textBody: "Hello",
            htmlBody: "<p>Hello</p>",
            attachments: [regularAttachment]
        )

        let content = email.constructContent()
        let altBoundary = try #require(boundaryValue(in: content, named: "SwiftSMTP-Alt-Boundary-"))
        let altClose = "--\(altBoundary)--\r\n"

        let altCloseRange = try #require(content.range(of: altClose))
        let pdfPartRange = try #require(content.range(of: "Content-Type: application/pdf"))
        #expect(altCloseRange.upperBound < pdfPartRange.lowerBound)
    }

    @Test
    func testConstructContentClosesRelatedBoundaryBeforeRegularAttachment() throws {
        let inlineAttachment = Attachment(
            filename: "inline.png",
            mimeType: "image/png",
            data: Data(repeating: 0x42, count: 16),
            contentID: "inline-img",
            isInline: true
        )
        let regularAttachment = Attachment(
            filename: "report.pdf",
            mimeType: "application/pdf",
            data: Data(repeating: 0x5A, count: 16)
        )
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "HTML + inline + regular",
            textBody: "Hello",
            htmlBody: "<p>Hello<img src=\"cid:inline-img\"></p>",
            attachments: [inlineAttachment, regularAttachment]
        )

        let content = email.constructContent()
        let relatedBoundary = try #require(boundaryValue(in: content, named: "SwiftSMTP-Related-Boundary-"))
        let relatedClose = "--\(relatedBoundary)--\r\n"

        let relatedCloseRange = try #require(content.range(of: relatedClose))
        let pdfPartRange = try #require(content.range(of: "Content-Type: application/pdf"))
        #expect(relatedCloseRange.upperBound < pdfPartRange.lowerBound)
    }

    // Regression test for #168: base64-wrapped attachment bodies must use CRLF
    // line endings, not bare CR, or some clients save the raw base64 as the file.
    @Test
    func testRegularAttachmentBase64UsesCRLFLineEndings() {
        // 512 bytes encodes to enough base64 to wrap across multiple 76-char lines.
        let regularAttachment = Attachment(
            filename: "attachment.bin",
            mimeType: "application/octet-stream",
            data: Data(repeating: 0xAB, count: 512)
        )
        let email = Email(
            sender: EmailAddress(name: "Sender", address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Attachment test",
            textBody: "Testing attachment encoding.",
            attachments: [regularAttachment]
        )

        let rawData = Data(email.constructContent().utf8)
        #expect(bareCarriageReturnOffsets(in: rawData).isEmpty, "Found bare CR in MIME message")
    }

    @Test
    func testInlineAttachmentBase64UsesCRLFLineEndings() {
        let inlineAttachment = Attachment(
            filename: "inline.png",
            mimeType: "image/png",
            data: Data(repeating: 0x42, count: 512),
            contentID: "inline-img",
            isInline: true
        )
        let email = Email(
            sender: EmailAddress(name: "Sender", address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Inline attachment test",
            textBody: "Testing inline attachment encoding.",
            htmlBody: "<p>Hello<img src=\"cid:inline-img\"></p>",
            attachments: [inlineAttachment]
        )

        let rawData = Data(email.constructContent().utf8)
        #expect(bareCarriageReturnOffsets(in: rawData).isEmpty, "Found bare CR in MIME message")
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
        let rawMessage = Data("Subject: Test\r\n\r\nBody".utf8)
        let sender = EmailAddress(address: "sender@example.com")

        await #expect(throws: SMTPError.self) {
            try await server.sendRawMessage(rawMessage, from: sender, to: [])
        }
    }

    @Test
    func testSendRawMessageRequiresConnection() async {
        let server = SMTPServer(host: "smtp.example.com", port: 587)
        let rawMessage = Data("Subject: Test\r\n\r\nBody".utf8)
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

    // MARK: - Dot-Stuffing (RFC 5321 §4.5.2)

    @Test
    func testDotStuffNoLeadingDots() {
        let input = Data("Hello\r\nWorld\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == input)
    }

    @Test
    func testDotStuffLeadingDotOnFirstLine() {
        let input = Data(".hidden\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == Data("..hidden\r\n".utf8))
    }

    @Test
    func testDotStuffLeadingDotAfterCRLF() {
        let input = Data("Hello\r\n.World\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == Data("Hello\r\n..World\r\n".utf8))
    }

    @Test
    func testDotStuffMultipleLeadingDots() {
        let input = Data(".first\r\nsafe\r\n.second\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == Data("..first\r\nsafe\r\n..second\r\n".utf8))
    }

    @Test
    func testDotStuffLineThatIsJustADot() {
        // A bare ".\r\n" without stuffing would terminate DATA prematurely
        let input = Data("line1\r\n.\r\nline3\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == Data("line1\r\n..\r\nline3\r\n".utf8))
    }

    @Test
    func testDotStuffDotsInMiddleOfLineAreUntouched() {
        let input = Data("no.dots.at.start\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == input)
    }

    @Test
    func testDotStuffEmptyData() {
        let input = Data()
        let output = SendContentCommand.dotStuff(input)
        #expect(output.isEmpty)
    }

    @Test
    func testDotStuffConsecutiveDottedLines() {
        let input = Data(".a\r\n.b\r\n.c\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == Data("..a\r\n..b\r\n..c\r\n".utf8))
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
            (
                .messageTooLarge(messageSizeOctets: 100, maximumMessageSizeOctets: 50),
                "SMTP message too large: 100 bytes exceeds 50 byte limit"
            )
        ]
        for (error, expected) in cases {
            let asError: Error = error
            #expect(asError.localizedDescription == expected)
        }
    }

    /// Extract the boundary value that follows the given prefix (UUID is appended at runtime).
    private func boundaryValue(in content: String, named prefix: String) -> String? {
        let search = "boundary=\"\(prefix)"
        guard let prefixStart = content.range(of: search),
              let closingQuote = content.range(of: "\"", range: prefixStart.upperBound..<content.endIndex)
        else { return nil }
        let valueStart = content.index(prefixStart.upperBound, offsetBy: -prefix.count)
        return String(content[valueStart..<closingQuote.lowerBound])
    }

    /// Byte offsets of any carriage return (0x0D) not immediately followed by a
    /// line feed (0x0A). MIME bodies must only ever contain CRLF, never bare CR.
    private func bareCarriageReturnOffsets(in data: Data) -> [Int] {
        let bytes = Array(data)
        var offsets: [Int] = []
        for index in bytes.indices where bytes[index] == 0x0D {
            let next = index + 1
            if next >= bytes.count || bytes[next] != 0x0A {
                offsets.append(index)
            }
        }
        return offsets
    }
}
// swiftlint:enable file_length type_body_length
