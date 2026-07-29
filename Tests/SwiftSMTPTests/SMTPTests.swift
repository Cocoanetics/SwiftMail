// Splitting this test file was tried but introduced a macOS CI hang;
// see the IMAPTestServer.swift comment for context.
// swiftlint:disable file_length type_body_length

import Foundation
import NIOCore
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

    // RFC 6047 iMIP: a message whose only attachment is a text/calendar invite
    // is shipped as multipart/alternative with the ICS verbatim as 7bit, so
    // clients render their Accept/Decline UI.
    @Test
    func testConstructContentFormatsSingleCalendarInviteAsAlternative() throws {
        let ics = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\n"
            + "UID:imip-test-1\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let invite = Attachment(
            filename: "invite.ics",
            mimeType: "text/calendar; method=REQUEST; charset=UTF-8",
            data: Data(ics.utf8)
        )
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Invite",
            textBody: "You are invited.",
            attachments: [invite]
        )

        let content = email.constructContent()

        #expect(content.contains("Content-Type: multipart/alternative; boundary="))
        #expect(!content.contains("Content-Type: multipart/mixed"))
        #expect(content.contains(
            "Content-Type: text/calendar; method=REQUEST; charset=UTF-8\r\n"
                + "Content-Transfer-Encoding: 7bit\r\n\r\n" + ics
        ))
        #expect(!content.contains("Content-Disposition: attachment"))
    }

    // RFC 6047 iMIP: in a multipart/mixed message, a text/calendar attachment is
    // shipped inline as 7bit text while other attachments stay base64.
    @Test
    func testConstructContentShipsCalendarAttachmentInlineInMixedMessage() throws {
        let ics = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\n"
            + "UID:imip-test-2\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let invite = Attachment(
            filename: "invite.ics",
            mimeType: "text/calendar; method=REQUEST; charset=UTF-8",
            data: Data(ics.utf8)
        )
        let report = Attachment(
            filename: "report.pdf",
            mimeType: "application/pdf",
            data: Data(repeating: 0x5A, count: 16)
        )
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Invite plus report",
            textBody: "You are invited.",
            attachments: [invite, report]
        )

        let content = email.constructContent()

        #expect(content.contains("Content-Type: multipart/mixed; boundary="))
        let calendarPart = try #require(content.range(of: "Content-Type: text/calendar; method=REQUEST; charset=UTF-8"))
        let calendarTail = String(content[calendarPart.lowerBound...])
        #expect(calendarTail.contains(
            "Content-Transfer-Encoding: 7bit\r\n"
                + "Content-Disposition: inline; filename=\"invite.ics\"\r\n\r\n" + ics
        ))
        #expect(content.contains("Content-Disposition: attachment; filename=\"report.pdf\""))
    }

    // ICS producers commonly emit bare-LF line endings; the verbatim 7bit path
    // must normalize to CRLF or SMTP DATA framing (and dot-stuffing) breaks.
    @Test
    func testConstructContentNormalizesBareLFCalendarDataToCRLF() throws {
        let ics = "BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:imip-test-3\nEND:VEVENT\nEND:VCALENDAR\n"
        let invite = Attachment(
            filename: "invite.ics",
            mimeType: "text/calendar; method=REQUEST; charset=UTF-8",
            data: Data(ics.utf8)
        )
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Invite",
            textBody: "You are invited.",
            attachments: [invite]
        )

        let content = email.constructContent()

        #expect(content.contains("BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\n"))
        var previousByte: UInt8 = 0
        var foundBareLF = false
        for byte in Data(content.utf8) {
            if byte == 0x0A && previousByte != 0x0D {
                foundBareLF = true
                break
            }
            previousByte = byte
        }
        #expect(!foundBareLF, "Found bare LF in MIME message")
    }

    // A text/calendar attachment whose data is not valid UTF-8 falls back to the
    // regular base64 attachment path instead of corrupting the message body.
    @Test
    func testConstructContentFallsBackToBase64ForNonUTF8CalendarData() throws {
        let invite = Attachment(
            filename: "invite.ics",
            mimeType: "text/calendar; method=REQUEST; charset=UTF-8",
            data: Data([0xFF, 0xFE, 0xFD])
        )
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Broken invite",
            textBody: "You are invited.",
            attachments: [invite]
        )

        let content = email.constructContent()

        #expect(content.contains("Content-Type: multipart/mixed; boundary="))
        #expect(content.contains("Content-Disposition: attachment; filename=\"invite.ics\""))
        #expect(content.contains("Content-Transfer-Encoding: base64"))
    }

    // RFC 2045 §6.2: `7bit` means no octet > 127. Real invites carry non-ASCII in
    // SUMMARY/LOCATION/attendee names, so when the server advertised 8BITMIME the
    // ICS ships verbatim under an honest `8bit` label — not `7bit`, not base64.
    @Test
    func testConstructContentLabelsNonASCIICalendarAs8BitWhenServerSupports8BitMIME() throws {
        let ics = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:imip-test-5\r\n"
            + "SUMMARY:Besprechung mit Herrn Müller\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let invite = Attachment(
            filename: "invite.ics",
            mimeType: "text/calendar; method=REQUEST; charset=UTF-8",
            data: Data(ics.utf8)
        )
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Invite",
            textBody: "You are invited.",
            attachments: [invite]
        )

        let content = email.constructContent(use8BitMIME: true)

        #expect(content.contains("Content-Type: multipart/alternative; boundary="))
        #expect(content.contains(
            "Content-Type: text/calendar; method=REQUEST; charset=UTF-8\r\n"
                + "Content-Transfer-Encoding: 8bit\r\n\r\n" + ics
        ))
        #expect(content.contains("Müller"))
        #expect(!content.contains("Content-Disposition: attachment"))
    }

    // Without a negotiated 8BITMIME, non-ASCII ICS must NOT go on the wire under a
    // 7bit/8bit label (an MTA may strip the high bits and corrupt the invite) — it
    // falls back to the regular base64 attachment path instead.
    @Test
    func testConstructContentFallsBackToBase64ForNonASCIICalendarWithout8BitMIME() throws {
        let ics = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:imip-test-6\r\n"
            + "SUMMARY:Besprechung mit Herrn Müller\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let invite = Attachment(
            filename: "invite.ics",
            mimeType: "text/calendar; method=REQUEST; charset=UTF-8",
            data: Data(ics.utf8)
        )
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Invite",
            textBody: "You are invited.",
            attachments: [invite]
        )

        let content = email.constructContent(use8BitMIME: false)

        #expect(content.contains("Content-Type: multipart/mixed; boundary="))
        #expect(content.contains("Content-Disposition: attachment; filename=\"invite.ics\""))
        #expect(content.contains("Content-Transfer-Encoding: base64"))
        #expect(!content.contains("Content-Transfer-Encoding: 8bit"))
    }

    // RFC 5322 caps a line at 998 octets; unfolded ICS producers (long DESCRIPTION,
    // X-ALT-DESC with HTML) routinely exceed it. Such content must not ship verbatim
    // even on an 8BITMIME server — it falls back to the line-wrapped base64 path.
    @Test
    func testConstructContentFallsBackToBase64ForOverlongCalendarLine() throws {
        let longDescription = String(repeating: "x", count: 1500)
        let ics = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:imip-test-7\r\n"
            + "DESCRIPTION:\(longDescription)\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let invite = Attachment(
            filename: "invite.ics",
            mimeType: "text/calendar; method=REQUEST; charset=UTF-8",
            data: Data(ics.utf8)
        )
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Invite",
            textBody: "You are invited.",
            attachments: [invite]
        )

        let content = email.constructContent(use8BitMIME: true)

        #expect(content.contains("Content-Disposition: attachment; filename=\"invite.ics\""))
        #expect(content.contains("Content-Transfer-Encoding: base64"))
        #expect(!content.contains("Content-Transfer-Encoding: 7bit"))
        #expect(!content.contains(longDescription))
    }

    // The 998-octet limit must be measured in octets, not grapheme clusters: a line
    // of 600 two-byte characters is 1200 octets (only 600 Characters), so it must
    // fall back to base64 even on an 8BITMIME server rather than ship verbatim 8bit.
    @Test
    func testConstructContentFallsBackToBase64ForOverlongMultibyteCalendarLine() throws {
        let longSummary = String(repeating: "ü", count: 600) // 600 Characters, 1200 UTF-8 octets
        let ics = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:imip-test-8\r\n"
            + "SUMMARY:\(longSummary)\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let invite = Attachment(
            filename: "invite.ics",
            mimeType: "text/calendar; method=REQUEST; charset=UTF-8",
            data: Data(ics.utf8)
        )
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Invite",
            textBody: "You are invited.",
            attachments: [invite]
        )

        let content = email.constructContent(use8BitMIME: true)

        // The calendar part took the base64 attachment fallback, not the inline path,
        // and the over-long multibyte line is nowhere on the wire verbatim.
        #expect(content.contains("Content-Disposition: attachment; filename=\"invite.ics\""))
        #expect(content.contains("Content-Transfer-Encoding: base64"))
        #expect(!content.contains(longSummary))
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

    // MARK: - SMTP submission outcome classification (unit)

    @Test
    func testContentPhaseReplyClassification() {
        let transient = SMTPSendError.classifyingPostContentDispatch(
            SMTPError.unexpectedResponse(SMTPResponse(code: 452, message: "452 4.2.2 Mailbox full"))
        )
        #expect(transient.phase == .content)
        #expect(transient.acceptance == .rejectedTransiently)
        #expect(transient.response?.code == 452)
        #expect(transient.retryDisposition == .retryable)

        let permanent = SMTPSendError.classifyingPostContentDispatch(
            SMTPError.unexpectedResponse(SMTPResponse(code: 554, message: "554 5.7.1 Rejected"))
        )
        #expect(permanent.acceptance == .rejectedPermanently)
        #expect(permanent.retryDisposition == .permanent)

        // A malformed or intermediate reply after the terminator proves nothing
        // about acceptance, so it must not be treated as a rejection.
        let weird = SMTPSendError.classifyingPostContentDispatch(
            SMTPError.unexpectedResponse(SMTPResponse(code: 334, message: "334 unexpected"))
        )
        #expect(weird.acceptance == .ambiguous)
        #expect(weird.retryDisposition == .unsafeToRetry)
    }

    @Test
    func testContentPhaseTransportClassification() {
        struct OpaqueTLSError: Error {}

        let timedOut = SMTPSendError.classifyingPostContentDispatch(SMTPSubmissionTimeoutError())
        #expect(timedOut.reason == .timedOut)
        #expect(timedOut.acceptance == .ambiguous)
        #expect(timedOut.retryDisposition == .unsafeToRetry)

        let eof = SMTPSendError.classifyingPostContentDispatch(
            SMTPError.connectionFailed("Connection closed")
        )
        #expect(eof.reason == .connectionLost)
        #expect(eof.acceptance == .ambiguous)
        #expect(eof.retryDisposition == .unsafeToRetry)

        let cancelled = SMTPSendError.classifyingPostContentDispatch(CancellationError())
        #expect(cancelled.reason == .cancelled)
        #expect(cancelled.acceptance == .ambiguous)
        #expect(cancelled.retryDisposition == .unsafeToRetry)

        let closedChannel = SMTPSendError.classifyingPostContentDispatch(ChannelError.ioOnClosedChannel)
        #expect(closedChannel.reason == .connectionLost)
        #expect(closedChannel.acceptance == .ambiguous)

        let channelEOF = SMTPSendError.classifyingPostContentDispatch(ChannelError.eof)
        #expect(channelEOF.reason == .connectionLost)

        let inputClosed = SMTPSendError.classifyingPostContentDispatch(ChannelError.inputClosed)
        #expect(inputClosed.reason == .connectionLost)

        let opaque = SMTPSendError.classifyingPostContentDispatch(OpaqueTLSError())
        if case .transport = opaque.reason {
            // expected
        } else {
            Issue.record("Expected transport reason, got \(opaque.reason)")
        }
        #expect(opaque.acceptance == .ambiguous)
        #expect(opaque.retryDisposition == .unsafeToRetry)
    }

    @Test
    func testPreContentPhaseClassification() {
        let recipient = EmailAddress(address: "bob@example.com")

        let mailFromRejected = SMTPSendError.classifyingPreContent(
            SMTPError.unexpectedResponse(SMTPResponse(code: 451, message: "451 4.3.2 Try again")),
            phase: .mailFrom
        )
        #expect(mailFromRejected.phase == .mailFrom)
        #expect(mailFromRejected.acceptance == .notAccepted)
        #expect(mailFromRejected.response?.code == 451)
        #expect(mailFromRejected.retryDisposition == .retryable)
        #expect(mailFromRejected.rejectedRecipient == nil)

        let recipientRejected = SMTPSendError.classifyingPreContent(
            SMTPError.unexpectedResponse(SMTPResponse(code: 550, message: "550 5.1.1 User unknown")),
            phase: .rcptTo,
            recipient: recipient
        )
        #expect(recipientRejected.phase == .rcptTo)
        #expect(recipientRejected.acceptance == .notAccepted)
        #expect(recipientRejected.rejectedRecipient == recipient)
        // A 5xx before content is a proven non-acceptance, but retrying the
        // identical message cannot succeed.
        #expect(recipientRejected.retryDisposition == .permanent)

        // A RCPT TO timeout is not a rejection of that recipient.
        let recipientTimeout = SMTPSendError.classifyingPreContent(
            SMTPSubmissionTimeoutError(),
            phase: .rcptTo,
            recipient: recipient
        )
        #expect(recipientTimeout.rejectedRecipient == nil)
        #expect(recipientTimeout.reason == .timedOut)
        #expect(recipientTimeout.acceptance == .notAccepted)
        #expect(recipientTimeout.retryDisposition == .retryable)

        let dataRejected = SMTPSendError.classifyingPreContent(
            SMTPError.unexpectedResponse(SMTPResponse(code: 451, message: "451 4.3.2 Cannot accept now")),
            phase: .data
        )
        #expect(dataRejected.phase == .data)
        #expect(dataRejected.acceptance == .notAccepted)
        #expect(dataRejected.retryDisposition == .retryable)

        // Cancellation caught immediately before the first content byte was
        // written is the one provably-safe content-phase outcome.
        let cancelledBeforeContent = SMTPSendError.classifyingPreContent(CancellationError(), phase: .content)
        #expect(cancelledBeforeContent.phase == .content)
        #expect(cancelledBeforeContent.acceptance == .notAccepted)
        #expect(cancelledBeforeContent.reason == .cancelled)
        #expect(cancelledBeforeContent.retryDisposition == .retryable)
    }

    /// A consumer-style outbox policy built purely on typed fields — proving
    /// the acceptance criterion that retry decisions need no error-string parsing.
    @Test
    func testRetryPolicyNeedsNoStringParsing() {
        enum OutboxAction: Equatable {
            case requeue
            case dropPermanently
            case holdForManualReview
        }

        func outboxAction(for error: Error) -> OutboxAction {
            guard let sendError = error as? SMTPSendError else {
                // Contract: everything else failed before the server saw the
                // transaction, so normal retry policy applies.
                return .requeue
            }
            switch sendError.retryDisposition {
                case .retryable:
                    return .requeue
                case .permanent:
                    return .dropPermanently
                case .unsafeToRetry:
                    return .holdForManualReview
            }
        }

        #expect(outboxAction(for: SMTPError.connectionFailed("Not connected")) == .requeue)
        #expect(outboxAction(for: SMTPSendError(
            phase: .rcptTo,
            acceptance: .notAccepted,
            reason: .reply(SMTPResponse(code: 550, message: "550 5.1.1 User unknown")),
            rejectedRecipient: EmailAddress(address: "bob@example.com")
        )) == .dropPermanently)
        #expect(outboxAction(for: SMTPSendError(
            phase: .mailFrom,
            acceptance: .notAccepted,
            reason: .reply(SMTPResponse(code: 451, message: "451 4.3.2 Try again"))
        )) == .requeue)
        #expect(outboxAction(for: SMTPSendError(
            phase: .content,
            acceptance: .rejectedTransiently,
            reason: .reply(SMTPResponse(code: 452, message: "452 4.2.2 Mailbox full"))
        )) == .requeue)
        #expect(outboxAction(for: SMTPSendError(
            phase: .content,
            acceptance: .rejectedPermanently,
            reason: .reply(SMTPResponse(code: 554, message: "554 5.7.1 Rejected"))
        )) == .dropPermanently)
        #expect(outboxAction(for: SMTPSendError(
            phase: .content,
            acceptance: .ambiguous,
            reason: .timedOut
        )) == .holdForManualReview)
        #expect(outboxAction(for: SMTPSendError(
            phase: .content,
            acceptance: .ambiguous,
            reason: .cancelled
        )) == .holdForManualReview)
    }

    @Test
    func testSendErrorDescriptionsAreInformative() {
        let error = SMTPSendError(
            phase: .rcptTo,
            acceptance: .notAccepted,
            reason: .reply(SMTPResponse(code: 550, message: "550 5.1.1 User unknown")),
            rejectedRecipient: EmailAddress(address: "bob@example.com")
        )
        #expect(error.description.contains("RCPT TO"))
        #expect(error.description.contains("bob@example.com"))
        #expect(error.description.contains("550"))
        #expect(error.localizedDescription == error.description)

        let ambiguous = SMTPSendError(phase: .content, acceptance: .ambiguous, reason: .connectionLost)
        #expect(ambiguous.description.contains("connection lost"))
        #expect(ambiguous.description.contains("acceptance unknown"))
    }

    @Test
    func testRsetCommandString() {
        #expect(RsetCommand().toCommandString() == "RSET")
    }

    #if os(macOS) || os(Linux)

    // MARK: - Submission outcome integration tests (scripted fake server)

    private static func makeOutcomeTestEmail(
        recipients: [EmailAddress] = [EmailAddress(address: "recipient@example.com")]
    ) -> Email {
        Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: recipients,
            subject: "Outcome test",
            textBody: "Hello"
        )
    }

    /// Starts a scripted server, connects a plaintext client to it, runs `body`,
    /// and tears both down afterwards — on success and on throw alike.
    private func withScriptedServer(
        _ script: SMTPServerScript = SMTPServerScript(),
        ehloCapabilities: [String] = ["8BITMIME"],
        _ body: (SMTPTestServer, SMTPServer) async throws -> Void
    ) async throws {
        let testServer = SMTPTestServer(script: script, ehloCapabilities: ehloCapabilities)
        try testServer.start()
        try await testServer.run {
            let client = SMTPServer(host: "127.0.0.1", port: testServer.port, transportSecurity: .plainText)
            try await client.connect()
            do {
                try await body(testServer, client)
                try? await client.disconnect()
            } catch {
                try? await client.disconnect()
                throw error
            }
        }
    }

    @Test
    func testSendEmailAcceptedReturnsFinalReply() async throws {
        try await withScriptedServer { server, client in
            let result = try await client.sendEmail(Self.makeOutcomeTestEmail())
            #expect(result.response.code == 250)
            #expect(result.response.message.contains("queued as TEST42"))

            // The session stays usable: a second transaction on the same
            // connection must succeed as well.
            let second = try await client.sendEmail(Self.makeOutcomeTestEmail())
            #expect(second.response.code == 250)

            #expect(server.receivedCommandCount(withPrefix: "MAIL FROM") == 2)
            #expect(server.receivedContentMessages.count == 2)
        }
    }

    @Test
    func testSendEmailTransientRejectionAfterContent() async throws {
        var script = SMTPServerScript()
        script.onContent = [.reply("452 4.2.2 Mailbox full")]
        try await withScriptedServer(script) { server, client in
            let sendError = await #expect(throws: SMTPSendError.self) {
                _ = try await client.sendEmail(Self.makeOutcomeTestEmail())
            }
            #expect(sendError?.phase == .content)
            #expect(sendError?.acceptance == .rejectedTransiently)
            #expect(sendError?.response?.code == 452)
            #expect(sendError?.retryDisposition == .retryable)

            // The transaction concluded with a final reply: the session is in
            // command state and needs no RSET, and the connection stays open.
            #expect(server.receivedCommandCount(withPrefix: "RSET") == 0)
            let hasChannel = await client.hasChannelForTesting
            #expect(hasChannel)
        }
    }

    @Test
    func testSendEmailPermanentRejectionAfterContent() async throws {
        var script = SMTPServerScript()
        script.onContent = [.reply("554 5.7.1 Message rejected")]
        try await withScriptedServer(script) { server, client in
            let sendError = await #expect(throws: SMTPSendError.self) {
                _ = try await client.sendEmail(Self.makeOutcomeTestEmail())
            }
            #expect(sendError?.phase == .content)
            #expect(sendError?.acceptance == .rejectedPermanently)
            #expect(sendError?.response?.code == 554)
            #expect(sendError?.retryDisposition == .permanent)
            #expect(server.receivedContentMessages.count == 1)
            let hasChannel = await client.hasChannelForTesting
            #expect(hasChannel)
        }
    }

    @Test
    func testUnexpectedReplyAfterContentIsAmbiguousAndClosesConnection() async throws {
        var script = SMTPServerScript()
        script.onContent = [.reply("334 Unexpected continuation")]
        try await withScriptedServer(script) { server, client in
            let sendError = await #expect(throws: SMTPSendError.self) {
                _ = try await client.sendEmail(Self.makeOutcomeTestEmail())
            }
            #expect(server.receivedContentMessages.count == 1)
            #expect(sendError?.phase == .content)
            #expect(sendError?.acceptance == .ambiguous)
            #expect(sendError?.response?.code == 334)
            #expect(sendError?.retryDisposition == .unsafeToRetry)

            let hasChannel = await client.hasChannelForTesting
            #expect(!hasChannel)
        }
    }

    @Test
    func testSendEmailAmbiguousWhenConnectionClosesAfterTerminator() async throws {
        var script = SMTPServerScript()
        script.onContent = [.close]
        try await withScriptedServer(script) { server, client in
            let sendError = await #expect(throws: SMTPSendError.self) {
                _ = try await client.sendEmail(Self.makeOutcomeTestEmail())
            }
            #expect(server.receivedContentMessages.count == 1)
            #expect(sendError?.phase == .content)
            #expect(sendError?.acceptance == .ambiguous)
            #expect(sendError?.reason == .connectionLost)
            #expect(sendError?.retryDisposition == .unsafeToRetry)

            // The connection is unusable and gets torn down.
            let hasChannel = await client.hasChannelForTesting
            #expect(!hasChannel)
        }
    }

    @Test
    func testSendEmailAmbiguousWhenFinalReplyTimesOut() async throws {
        var script = SMTPServerScript()
        script.onContent = [.silence]
        try await withScriptedServer(script) { server, client in
            await client.setSubmissionTimeoutSecondsForTesting(1)
            let sendError = await #expect(throws: SMTPSendError.self) {
                _ = try await client.sendEmail(Self.makeOutcomeTestEmail())
            }
            #expect(server.receivedContentMessages.count == 1)
            #expect(sendError?.phase == .content)
            #expect(sendError?.acceptance == .ambiguous)
            #expect(sendError?.reason == .timedOut)
            #expect(sendError?.retryDisposition == .unsafeToRetry)
            let hasChannel = await client.hasChannelForTesting
            #expect(!hasChannel)
        }
    }

    @Test
    func testSendEmailAmbiguousWhenCancelledAfterTerminator() async throws {
        var script = SMTPServerScript()
        script.onContent = [.silence]
        try await withScriptedServer(script) { server, client in
            let email = Self.makeOutcomeTestEmail()
            let sendTask = Task {
                try await client.sendEmail(email)
            }

            // Cancel only once the server has provably received the whole
            // message including the terminating <CRLF>.<CRLF>.
            await server.waitForContentTerminator()
            sendTask.cancel()

            switch await sendTask.result {
                case .success:
                    Issue.record("Expected cancellation to fail the send")
                case .failure(let error):
                    guard let sendError = error as? SMTPSendError else {
                        Issue.record("Expected SMTPSendError, got \(error)")
                        return
                    }
                    #expect(sendError.phase == .content)
                    #expect(sendError.acceptance == .ambiguous)
                    #expect(sendError.reason == .cancelled)
                    #expect(sendError.retryDisposition == .unsafeToRetry)
            }

            let hasChannel = await client.hasChannelForTesting
            #expect(!hasChannel)
        }
    }

    @Test
    func testRecipientRejectionAbortsTransactionBeforeData() async throws {
        var script = SMTPServerScript()
        script.onRcptTo = [.reply("550 5.1.1 User unknown")]
        let firstRecipient = EmailAddress(address: "first@example.com")
        let secondRecipient = EmailAddress(address: "second@example.com")
        try await withScriptedServer(script) { server, client in
            let sendError = await #expect(throws: SMTPSendError.self) {
                _ = try await client.sendEmail(
                    Self.makeOutcomeTestEmail(recipients: [firstRecipient, secondRecipient])
                )
            }
            #expect(sendError?.phase == .rcptTo)
            #expect(sendError?.acceptance == .notAccepted)
            #expect(sendError?.rejectedRecipient == firstRecipient)
            #expect(sendError?.retryDisposition == .permanent)

            // All-or-nothing: the first rejection aborts the transaction —
            // no further RCPT TO, no DATA, no content — and RSET cleans up.
            #expect(server.receivedCommandCount(withPrefix: "RCPT TO") == 1)
            #expect(server.receivedCommandCount(withPrefix: "DATA") == 0)
            #expect(server.receivedContentMessages.isEmpty)
            #expect(server.receivedCommandCount(withPrefix: "RSET") == 1)
            let hasChannel = await client.hasChannelForTesting
            #expect(hasChannel)
        }
    }

    @Test
    func testSecondSendSucceedsOnSameConnectionAfterRejectedTransaction() async throws {
        var script = SMTPServerScript()
        script.onRcptTo = [.reply("451 4.7.1 Greylisted, try again later"), .reply("250 OK")]
        try await withScriptedServer(script) { server, client in
            let sendError = await #expect(throws: SMTPSendError.self) {
                _ = try await client.sendEmail(Self.makeOutcomeTestEmail())
            }
            #expect(sendError?.phase == .rcptTo)
            #expect(sendError?.retryDisposition == .retryable)

            // RSET concluded the aborted transaction (RFC 5321 §4.3.1), so an
            // immediate retry on the same connection must succeed.
            let result = try await client.sendEmail(Self.makeOutcomeTestEmail())
            #expect(result.response.code == 250)
            #expect(server.receivedCommandCount(withPrefix: "RSET") == 1)
            #expect(server.receivedContentMessages.count == 1)
        }
    }

    @Test
    func testMailFromRejectionReportsPhase() async throws {
        var script = SMTPServerScript()
        script.onMailFrom = [.reply("451 4.3.2 Please try again later")]
        try await withScriptedServer(script) { server, client in
            let sendError = await #expect(throws: SMTPSendError.self) {
                _ = try await client.sendEmail(Self.makeOutcomeTestEmail())
            }
            #expect(sendError?.phase == .mailFrom)
            #expect(sendError?.acceptance == .notAccepted)
            #expect(sendError?.response?.code == 451)
            #expect(sendError?.retryDisposition == .retryable)
            #expect(sendError?.rejectedRecipient == nil)
            #expect(server.receivedCommandCount(withPrefix: "RCPT TO") == 0)
            #expect(server.receivedCommandCount(withPrefix: "DATA") == 0)
        }
    }

    @Test
    func testNon354DataReplySendsNoContent() async throws {
        var script = SMTPServerScript()
        // RFC 5321 §3.3: anything but 354 — even another 3xx — must not be
        // followed by message data.
        script.onData = [.reply("334 Not the go-ahead")]
        try await withScriptedServer(script) { server, client in
            let sendError = await #expect(throws: SMTPSendError.self) {
                _ = try await client.sendEmail(Self.makeOutcomeTestEmail())
            }
            #expect(sendError?.phase == .data)
            #expect(sendError?.acceptance == .notAccepted)
            #expect(sendError?.retryDisposition == .retryable)
            #expect(server.receivedContentMessages.isEmpty)
            #expect(server.receivedCommandCount(withPrefix: "RSET") == 1)

            let commands = server.recordedCommands
            let dataIndex = try #require(commands.firstIndex(where: { $0.uppercased() == "DATA" }))
            #expect(Array(commands.dropFirst(dataIndex + 1)) == ["RSET"])
        }
    }

    @Test
    func test421ReplyClosesConnectionWithoutReset() async throws {
        var script = SMTPServerScript()
        script.onRcptTo = [.replyThenClose("421 4.3.2 Service shutting down")]
        try await withScriptedServer(script) { server, client in
            let sendError = await #expect(throws: SMTPSendError.self) {
                _ = try await client.sendEmail(Self.makeOutcomeTestEmail())
            }
            #expect(sendError?.phase == .rcptTo)
            #expect(sendError?.response?.code == 421)
            #expect(sendError?.acceptance == .notAccepted)
            #expect(sendError?.retryDisposition == .retryable)
            #expect(server.receivedCommandCount(withPrefix: "RSET") == 0)
            let hasChannel = await client.hasChannelForTesting
            #expect(!hasChannel)
        }
    }

    @Test
    func testSendRawMessageAcceptedReturnsFinalReply() async throws {
        try await withScriptedServer { server, client in
            let result = try await client.sendRawMessage(
                Data("Subject: Raw\r\n\r\nRaw body\r\n".utf8),
                from: EmailAddress(address: "sender@example.com"),
                to: [EmailAddress(address: "recipient@example.com")]
            )
            #expect(result.response.code == 250)
            #expect(server.receivedContentMessages.count == 1)
        }
    }

    @Test
    func testSendRawMessagePermanentRejectionAfterContent() async throws {
        var script = SMTPServerScript()
        script.onContent = [.reply("554 5.7.1 Rejected")]
        try await withScriptedServer(script) { _, client in
            let sendError = await #expect(throws: SMTPSendError.self) {
                _ = try await client.sendRawMessage(
                    Data("Subject: Raw\r\n\r\nRaw body\r\n".utf8),
                    from: EmailAddress(address: "sender@example.com"),
                    to: [EmailAddress(address: "recipient@example.com")]
                )
            }
            #expect(sendError?.phase == .content)
            #expect(sendError?.acceptance == .rejectedPermanently)
            #expect(sendError?.retryDisposition == .permanent)
        }
    }

    @Test
    func testSendRawMessageAmbiguousWhenConnectionClosesAfterTerminator() async throws {
        var script = SMTPServerScript()
        script.onContent = [.close]
        try await withScriptedServer(script) { _, client in
            let sendError = await #expect(throws: SMTPSendError.self) {
                _ = try await client.sendRawMessage(
                    Data("Subject: Raw\r\n\r\nRaw body\r\n".utf8),
                    from: EmailAddress(address: "sender@example.com"),
                    to: [EmailAddress(address: "recipient@example.com")]
                )
            }
            #expect(sendError?.phase == .content)
            #expect(sendError?.acceptance == .ambiguous)
            #expect(sendError?.reason == .connectionLost)
            #expect(sendError?.retryDisposition == .unsafeToRetry)
        }
    }

    @Test
    func testSendRawMessageRecipientRejectionMatchesSendEmail() async throws {
        var script = SMTPServerScript()
        script.onRcptTo = [.reply("550 5.1.1 User unknown")]
        let recipient = EmailAddress(address: "bob@example.com")
        try await withScriptedServer(script) { server, client in
            let sendError = await #expect(throws: SMTPSendError.self) {
                _ = try await client.sendRawMessage(
                    Data("Subject: Raw\r\n\r\nRaw body\r\n".utf8),
                    from: EmailAddress(address: "sender@example.com"),
                    to: [recipient]
                )
            }
            #expect(sendError?.phase == .rcptTo)
            #expect(sendError?.rejectedRecipient == recipient)
            #expect(sendError?.retryDisposition == .permanent)
            #expect(server.receivedCommandCount(withPrefix: "DATA") == 0)
            #expect(server.receivedContentMessages.isEmpty)
        }
    }

    @Test
    func testResetCommandRoundTrip() async throws {
        try await withScriptedServer { server, client in
            let response = try await client.reset()
            #expect(response.code == 250)
            #expect(server.receivedCommandCount(withPrefix: "RSET") == 1)
        }
    }

    @Test
    func testSendEmailWithoutRecipientsFailsBeforeDialogue() async throws {
        try await withScriptedServer { server, client in
            await #expect(throws: SMTPError.self) {
                _ = try await client.sendEmail(Self.makeOutcomeTestEmail(recipients: []))
            }
            #expect(server.receivedCommandCount(withPrefix: "MAIL FROM") == 0)
        }
    }

    @Test
    func testEightBitContentWithout8BITMIMEFailsBeforeDialogue() async throws {
        try await withScriptedServer(SMTPServerScript(), ehloCapabilities: []) { server, client in
            await #expect(throws: SMTPError.self) {
                _ = try await client.sendRawMessage(
                    Data([0x48, 0x65, 0xFF, 0x0D, 0x0A]),
                    from: EmailAddress(address: "sender@example.com"),
                    to: [EmailAddress(address: "recipient@example.com")]
                )
            }
            #expect(server.receivedCommandCount(withPrefix: "MAIL FROM") == 0)
        }
    }

    #endif // os(macOS) || os(Linux)

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
