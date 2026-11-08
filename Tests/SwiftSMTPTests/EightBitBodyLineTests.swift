import Foundation
import Testing
@testable import SwiftMail

/// The bytes a message goes out with on an `8BITMIME` server: every line ends in
/// CRLF (RFC 5321 §2.3.8, RFC 5322 §2.3) and no line is longer than 998 octets
/// (RFC 5322 §2.1.1, RFC 6532 §3.4), whatever line endings and characters the
/// caller's bodies use.
struct EightBitBodyLineTests {
    /// Message shapes, one per body writer in `Email+Content.swift`.
    enum Shape: CaseIterable, CustomTestStringConvertible {
        case textOnly
        case textAndHTML
        case textWithAttachment
        case htmlWithAttachment
        case htmlWithInlineImage
        case textWithCalendarInvite

        var testDescription: String { "\(self)" }

        func email(text: String, html: String) -> Email {
            let attachment = SwiftMail.Attachment(
                filename: "report.pdf",
                mimeType: "application/pdf",
                data: Data(repeating: 0x5A, count: 64)
            )
            let inline = SwiftMail.Attachment(
                filename: "image.png",
                mimeType: "image/png",
                data: Data(repeating: 0x42, count: 64),
                contentID: "image",
                isInline: true
            )
            let invite = SwiftMail.Attachment(
                filename: "invite.ics",
                mimeType: "text/calendar; method=REQUEST",
                data: Data("BEGIN:VCALENDAR\nMETHOD:REQUEST\nEND:VCALENDAR\n".utf8)
            )
            switch self {
                case .textOnly:
                    return Self.message(text: text, html: nil, attachments: [])
                case .textAndHTML:
                    return Self.message(text: text, html: html, attachments: [])
                case .textWithAttachment:
                    return Self.message(text: text, html: nil, attachments: [attachment])
                case .htmlWithAttachment:
                    return Self.message(text: text, html: html, attachments: [attachment])
                case .htmlWithInlineImage:
                    return Self.message(text: text, html: html, attachments: [inline])
                case .textWithCalendarInvite:
                    return Self.message(text: text, html: nil, attachments: [invite])
            }
        }

        private static func message(text: String, html: String?, attachments: [SwiftMail.Attachment]) -> Email {
            Email(
                sender: EmailAddress(address: "sender@example.com"),
                recipients: [EmailAddress(address: "recipient@example.com")],
                subject: "Lines",
                textBody: text,
                htmlBody: html,
                attachments: attachments
            )
        }
    }

    /// Bodies whose line endings or line lengths the 8bit branch must not ship as written.
    enum Body: CaseIterable, CustomTestStringConvertible {
        case bareLF
        case bareCR
        case mixedLineEndings
        case threeOctetCharacters
        case emoji
        case joinedEmoji
        case lineSeparatorCharacter
        case lineBreakBeforeMark
        case markHidesOverlongLine

        var testDescription: String { "\(self)" }

        var text: String {
            switch self {
                case .bareLF:
                    return "first line\nsecond line\n\nlast line\n"
                case .bareCR:
                    return "first line\rsecond line\r"
                case .mixedLineEndings:
                    return "one\r\ntwo\nthree\rfour\n\rfive"
                case .threeOctetCharacters:
                    // 400 characters, 1,200 octets.
                    return "short line\n" + String(repeating: "\u{4E2D}", count: 400) + "\nshort line"
                case .emoji:
                    // 300 characters, 1,200 octets.
                    return String(repeating: "\u{1F600}", count: 300)
                case .joinedEmoji:
                    // 50 characters (one grapheme cluster each), 1,250 octets.
                    return String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", count: 50)
                case .lineSeparatorCharacter:
                    // U+2028 is not a line break in SMTP: this is one 1,203-octet line.
                    return String(repeating: "a", count: 600) + "\u{2028}" + String(repeating: "b", count: 600)
                case .lineBreakBeforeMark:
                    // A default search treats a break followed by a combining mark, a
                    // variation selector or an emoji modifier as one composed sequence.
                    return "one\n\u{301}two\r\u{FE0F}three\r\n\u{1F3FB}four"
                case .markHidesOverlongLine:
                    // Two 600-octet lines; the CR before the mark must still end the first.
                    return String(repeating: "a", count: 600) + "\r\u{301}" + String(repeating: "b", count: 600)
            }
        }

        var html: String { "<p>" + text + "</p>" }
    }

    @Test(arguments: Shape.allCases, Body.allCases)
    func sentBytesHaveCRLFLinesOfAtMost998Octets(shape: Shape, body: Body) throws {
        let email = shape.email(text: body.text, html: body.html)
        let prepared = try SMTPServer.prepareEmailForSend(email, capabilities: ["8BITMIME"])
        #expect(prepared.use8BitMIME)
        Self.expectWellFormedLines(Array(prepared.contentData))
        Self.expectWellFormedLines(Array(email.constructContent(use8BitMIME: true).utf8))
    }

    /// A body that already meets both rules still goes out as 8bit, its text unchanged
    /// apart from its line endings.
    @Test(arguments: Shape.allCases)
    func safeBodyStaysEightBitWithCRLFEndings(shape: Shape) throws {
        let text = "first line\nsecond \u{4E2D}\u{6587} line\rthird line\r\nfourth\r\n\u{301}fifth"
        let html = "<p>first\n\u{4E2D}\u{6587}\r\n\u{301}</p>"
        let email = shape.email(text: text, html: html)
        let content = email.constructContent(use8BitMIME: true)

        let textPart = "first line\r\nsecond \u{4E2D}\u{6587} line\r\nthird line\r\nfourth\r\n\u{301}fifth"
        #expect(content.contains("Content-Transfer-Encoding: 8bit\r\n\r\n" + textPart))
        if email.htmlBody != nil {
            let htmlPart = "<p>first\r\n\u{4E2D}\u{6587}\r\n\u{301}</p>"
            #expect(content.contains("Content-Transfer-Encoding: 8bit\r\n\r\n" + htmlPart))
        }
        #expect(!content.contains("quoted-printable"))
        Self.expectWellFormedLines(Array(content.utf8))
    }

    /// A calendar invite goes out inline as 8bit with every line ending written as
    /// CRLF, including a break directly before a combining mark, a variation
    /// selector or an emoji modifier.
    @Test
    func calendarInviteLinesEndInCRLF() throws {
        let ics = "BEGIN:VCALENDAR\nMETHOD:REQUEST\nX-NOTE:a\n\u{301}b\r\u{FE0F}c\r\n\u{1F3FB}d\nEND:VCALENDAR\n"
        let invite = SwiftMail.Attachment(
            filename: "invite.ics",
            mimeType: "text/calendar; method=REQUEST",
            data: Data(ics.utf8)
        )
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Invite",
            textBody: "Invitation",
            attachments: [invite]
        )
        let content = Data(email.constructContent(use8BitMIME: true).utf8)
        let calendarPart = "Content-Transfer-Encoding: 8bit\r\n\r\n"
            + "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nX-NOTE:a\r\n\u{301}b\r\n\u{FE0F}c\r\n"
            + "\u{1F3FB}d\r\nEND:VCALENDAR\r\n"
        #expect(content.range(of: Data(calendarPart.utf8)) != nil)
        Self.expectWellFormedLines(Array(content))
    }

    @Test
    func lineLimitIsCountedInOctets() {
        let threeOctets = "\u{4E2D}"
        #expect(String(repeating: threeOctets, count: 332).isSafe8BitContent()) // 996 octets
        #expect(!String(repeating: threeOctets, count: 333).isSafe8BitContent()) // 999 octets
        #expect(String(repeating: "a", count: 998).isSafe8BitContent())
        #expect(!String(repeating: "a", count: 999).isSafe8BitContent())
        #expect(!String(repeating: "\u{1F600}", count: 250).isSafe8BitContent()) // 1,000 octets
        for lineBreak in ["\n", "\r\n", "\r"] {
            #expect(("first" + lineBreak + String(repeating: "a", count: 998)).isSafe8BitContent())
            #expect(!("first" + lineBreak + String(repeating: "a", count: 999)).isSafe8BitContent())
        }
    }

    @Test
    func linesEndOnlyAtCROrLF() {
        let half = String(repeating: "a", count: 500)
        #expect((half + "\r\n" + half).isSafe8BitContent())
        #expect((half + "\n" + half).isSafe8BitContent())
        #expect((half + "\r" + half).isSafe8BitContent())
        #expect(!(half + "\u{2028}" + half).isSafe8BitContent())
        #expect(!(half + "\u{2029}" + half).isSafe8BitContent())
        #expect(!(half + "\u{85}" + half).isSafe8BitContent())
    }

    /// Every LF follows a CR, every CR precedes an LF, and every line between them
    /// is at most 998 octets.
    private static func expectWellFormedLines(_ bytes: [UInt8]) {
        var lineOctets = 0
        var longest = 0
        for index in bytes.indices {
            switch bytes[index] {
                case 0x0A:
                    #expect(index > 0 && bytes[index - 1] == 0x0D, "LF without CR at octet \(index)")
                    lineOctets = 0
                case 0x0D:
                    #expect(index + 1 < bytes.count && bytes[index + 1] == 0x0A, "CR without LF at octet \(index)")
                default:
                    lineOctets += 1
                    longest = max(longest, lineOctets)
            }
        }
        #expect(longest <= 998, "longest line is \(longest) octets")
    }
}
