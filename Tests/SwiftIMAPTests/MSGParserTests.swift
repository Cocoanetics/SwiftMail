// MSGParserTests.swift
// End-to-end tests for MSGParser over compound files built in memory.

import Testing
import Foundation
@testable import SwiftMail

@Suite("MSG Parser", .tags(.mime), .timeLimit(.minutes(1)))
struct MSGParserTests {

    // MARK: - Fixtures

    static let encapsulatedHTML = Data(#"""
    {\rtf1\ansi\ansicpg1252\fromhtml1 \deff0{\fonttbl{\f0\fswiss Helvetica;}}
    {\*\htmltag19 <html>}{\*\htmltag34 <body>}
    \htmlrtf {\f0 \htmlrtf0 Gr\'fc\'dfe aus Wien\htmlrtf\par}\htmlrtf0
    {\*\htmltag42 </body>}{\*\htmltag27 </html>}}
    """#.utf8)

    static let transportHeaders = """
    Received: from mail.example.com by mx.example.org; Tue, 15 Apr 2025 09:12:33 +0200
    From: Anna Beispiel <anna@example.com>
    To: Bernd Muster <bernd@example.org>
    Cc: archive@example.org
    Subject: =?utf-8?Q?Gr=C3=BC=C3=9Fe?=
    Date: Tue, 15 Apr 2025 09:12:30 +0200
    Message-ID: <abc123@example.com>
    Content-Type: multipart/related; boundary="x"
    """

    /// A `.msg` with a plain-text body, an encapsulated-HTML RTF body, an
    /// inline image, a PDF attachment, and one embedded message.
    static func sampleMSG(
        includeTransportHeaders: Bool = true,
        includeAttachments: Bool = true,
        includeEmbedded: Bool = true,
        rtf: Data? = MSGParserTests.encapsulatedHTML
    ) -> Data {
        var properties: [MAPIFixtureProperty] = [
            .unicode(.subject, "Grüße"),
            .unicode(.body, "Grüße aus Wien\n"),
            .unicode(.senderName, "Anna Beispiel"),
            .unicode(.senderSMTPAddress, "anna@example.com"),
            .systemTime(.clientSubmitTime, Date(timeIntervalSince1970: 1_744_701_150))
        ]
        if includeTransportHeaders {
            properties.append(.unicode(.transportMessageHeaders, transportHeaders))
        }
        if let rtf {
            properties.append(.binary(.rtfCompressed, lzfuCompress(rtf: rtf)))
        }

        var children: [CFBNode] = []
        if includeAttachments { children.append(contentsOf: attachmentNodes()) }
        if includeEmbedded { children.append(embeddedMessageNode()) }

        return CompoundFileBuilder.build(root: mapiNodes(properties, isTopLevel: true, extra: children))
    }

    /// One inline image and one file attachment, told apart only by
    /// `ATT_MHTML_REF` — both carry a Content-ID, as Outlook writes them.
    static func attachmentNodes() -> [CFBNode] {
        [
            .storage(name: "__attach_version1.0_#00000000", children: mapiNodes([
                .unicode(.attachLongFilename, "logo.png"),
                .unicode(.attachMIMETag, "image/png"),
                .unicode(.attachContentID, "<logo@example.com>"),
                .int32(.attachMethod, 1),
                .int32(.attachFlags, 5),
                .binary(.attachData, Data([0x89, 0x50, 0x4E, 0x47]))
            ], isTopLevel: false)),
            .storage(name: "__attach_version1.0_#00000001", children: mapiNodes([
                .unicode(.attachLongFilename, "vertrag.pdf"),
                .unicode(.attachMIMETag, "application/pdf"),
                .unicode(.attachContentID, "<doc@example.com>"),
                .int32(.attachMethod, 1),
                .binary(.attachData, Data("%PDF-1.7 fake".utf8))
            ], isTopLevel: false))
        ]
    }

    /// A forwarded message: no filename and no byte stream, just a storage
    /// holding another message with its own body and attachment.
    static func embeddedMessageNode() -> CFBNode {
        let inner = mapiNodes([
            .unicode(.subject, "Weitergeleitet"),
            .unicode(.body, "Innerer Text"),
            .unicode(.senderName, "Clara Vorbild"),
            .unicode(.senderSMTPAddress, "clara@example.net"),
            .binary(.rtfCompressed, lzfuCompress(rtf: encapsulatedHTML))
        ], isTopLevel: false, extra: [
            .storage(name: "__attach_version1.0_#00000000", children: mapiNodes([
                .unicode(.attachLongFilename, "innen.txt"),
                .unicode(.attachMIMETag, "text/plain"),
                .int32(.attachMethod, 1),
                .binary(.attachData, Data("innen".utf8))
            ], isTopLevel: false))
        ])

        return .storage(name: "__attach_version1.0_#00000002", children: mapiNodes([
            .int32(.attachMethod, 5)
        ], isTopLevel: false, extra: [
            .storage(name: "__substg1.0_3701000D", children: inner)
        ]))
    }

    // MARK: - Container

    @Test("Data that is not a compound file is rejected")
    func testRejectsNonCompoundFile() {
        #expect(throws: MSGParserError.self) {
            try MSGParser.parse(Data("From: someone@example.com\r\n\r\nhi".utf8))
        }
        #expect(throws: MSGParserError.self) { try MSGParser.parse(Data()) }
    }

    @Test("Truncating a valid container does not crash the parser")
    func testTruncatedContainer() {
        let full = Self.sampleMSG()
        for fraction in [2, 3, 4, 8] {
            let truncated = full.prefix(full.count / fraction)
            // Either outcome is fine; hanging or trapping is not.
            _ = try? MSGParser.parse(Data(truncated))
        }
    }

    // MARK: - Envelope

    @Test("Envelope comes from the original transport headers")
    func testEnvelopeFromTransportHeaders() throws {
        let message = try MSGParser.parse(Self.sampleMSG())

        #expect(message.subject == "Grüße")
        #expect(message.from?.contains("anna@example.com") == true)
        #expect(message.to.contains { $0.contains("bernd@example.org") })
        #expect(message.cc.contains { $0.contains("archive@example.org") })
        #expect(message.header.messageId?.description.contains("abc123@example.com") == true)

        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(secondsFromGMT: 0)!, from: try #require(message.date))
        #expect(components.year == 2025 && components.month == 4 && components.day == 15)
    }

    @Test("Without transport headers the envelope is rebuilt from MAPI properties")
    func testEnvelopeFromMAPIProperties() throws {
        let message = try MSGParser.parse(Self.sampleMSG(includeTransportHeaders: false))

        #expect(message.subject == "Grüße")
        #expect(message.from == "Anna Beispiel <anna@example.com>")
        #expect(message.date != nil)
    }

    @Test("Message(msgData:) is the same parse")
    func testConvenienceInitializer() throws {
        let message = try Message(msgData: Self.sampleMSG())
        #expect(message.subject == "Grüße")
    }

    // MARK: - Bodies

    @Test("Both bodies are present, with the HTML recovered from the RTF")
    func testBodies() throws {
        let message = try MSGParser.parse(Self.sampleMSG())

        #expect(message.textBody?.contains("Grüße aus Wien") == true)

        let html = try #require(message.htmlBody)
        #expect(html.contains("<html>"))
        #expect(html.contains("Grüße aus Wien"))
        #expect(html.contains("</html>"))
        // De-encapsulation is not a passthrough of the RTF.
        #expect(!html.contains("htmlrtf"))
        #expect(!html.contains("Helvetica"))
    }

    @Test("An encapsulated-text body is dropped as a duplicate of PR_BODY")
    func testEncapsulatedTextBodyIsNotDuplicated() throws {
        let rtf = Data(#"{\rtf1\ansi\fromtext \deff0 Gr\'fc\'dfe aus Wien\par}"#.utf8)
        let message = try MSGParser.parse(Self.sampleMSG(rtf: rtf))

        #expect(message.textBody?.contains("Grüße aus Wien") == true)
        #expect(message.htmlBody == nil)
        #expect(message.bodies.count == 1)
    }

    @Test("A genuine RTF body is passed through as application/rtf, not rendered")
    func testRealRTFBodyIsPassedThrough() throws {
        let rtf = Data(#"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\f0 Echtes RTF\par}"#.utf8)
        let message = try MSGParser.parse(Self.sampleMSG(rtf: rtf))

        #expect(message.htmlBody == nil)
        let rtfPart = try #require(message.parts.first { $0.contentType == "application/rtf" })
        #expect(rtfPart.data == rtf)
    }

    @Test("A message with no rich body still yields its plain text")
    func testPlainTextOnly() throws {
        let message = try MSGParser.parse(Self.sampleMSG(rtf: nil))

        #expect(message.textBody?.contains("Grüße aus Wien") == true)
        #expect(message.htmlBody == nil)
    }

    // MARK: - Attachments

    @Test("Attachments carry their name, type and bytes")
    func testAttachments() throws {
        let message = try MSGParser.parse(Self.sampleMSG())

        let pdf = try #require(message.parts.first { $0.filename == "vertrag.pdf" })
        #expect(pdf.contentType == "application/pdf")
        #expect(pdf.data == Data("%PDF-1.7 fake".utf8))
        // A Content-ID without ATT_MHTML_REF is still a file to save.
        #expect(pdf.disposition == "attachment")
        #expect(message.attachments.contains { $0.filename == "vertrag.pdf" })
    }

    @Test("An ATT_MHTML_REF attachment is inline and keeps its bare Content-ID")
    func testInlineAttachment() throws {
        let message = try MSGParser.parse(Self.sampleMSG())

        let logo = try #require(message.parts.first { $0.filename == "logo.png" })
        #expect(logo.disposition == "inline")
        #expect(logo.contentId == "logo@example.com")
        #expect(message.cids.contains { $0.filename == "logo.png" })
    }

    // MARK: - Embedded messages

    @Test("An embedded message becomes a message/rfc822 part with its envelope")
    func testEmbeddedMessagePart() throws {
        let message = try MSGParser.parse(Self.sampleMSG())

        let embedded = try #require(message.parts.first { $0.contentType == "message/rfc822" })
        let info = try #require(embedded.embeddedMessageInfo)
        #expect(info.subject == "Weitergeleitet")
        #expect(info.from == "Clara Vorbild <clara@example.net>")
        #expect(embedded.disposition == "attachment")
    }

    @Test("The embedded message's own parts are nested under its section")
    func testEmbeddedMessageSections() throws {
        let message = try MSGParser.parse(Self.sampleMSG())
        let embedded = try #require(message.parts.first { $0.contentType == "message/rfc822" })
        let prefix = embedded.section.components

        let nested = message.parts.filter {
            $0.section.components.count > prefix.count
                && Array($0.section.components.prefix(prefix.count)) == prefix
        }
        #expect(nested.count == 3)  // text, recovered html, one attachment
        #expect(nested.contains { $0.contentType.hasPrefix("text/html") })
        #expect(nested.contains { $0.filename == "innen.txt" })

        // Sections must stay unique so "3.2" addresses exactly one part.
        let sections = message.parts.map(\.section.description)
        #expect(Set(sections).count == sections.count)
    }

    @Test("Embedded messages are reachable as Messages in their own right")
    func testEmbeddedMessagesAccessor() throws {
        let message = try MSGParser.parse(Self.sampleMSG())

        let embedded = try #require(message.embeddedMessages.first)
        #expect(embedded.subject == "Weitergeleitet")
        #expect(embedded.textBody?.contains("Innerer Text") == true)
        #expect(embedded.htmlBody?.contains("<html>") == true)
        #expect(embedded.attachments.contains { $0.filename == "innen.txt" })
        // Renumbered as though parsed on its own.
        #expect(embedded.parts.first?.section.description == "1")
    }

    @Test("A forwarded message's own attachments do not surface as this message's")
    func testEmbeddedAttachmentsAreNotFlattened() throws {
        let message = try MSGParser.parse(Self.sampleMSG())

        // The embedded message is itself an attachment; its innen.txt is not.
        #expect(message.attachments.contains { $0.contentType == "message/rfc822" })
        #expect(!message.attachments.contains { $0.filename == "innen.txt" })

        let embedded = try #require(message.embeddedMessages.first)
        #expect(embedded.attachments.contains { $0.filename == "innen.txt" })
    }

    @Test("A message with nothing embedded has no embedded messages")
    func testNoEmbeddedMessages() throws {
        let message = try MSGParser.parse(Self.sampleMSG(includeEmbedded: false))
        #expect(message.embeddedMessages.isEmpty)
    }
}
