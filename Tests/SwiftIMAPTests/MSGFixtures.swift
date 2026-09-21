// MSGFixtures.swift
// The `.msg` containers MSGParserTests builds in memory.
//
// Kept beside the tests rather than inside them: a fixture that grows a new
// shape for each case is the bulk of the suite, and reading the assertions
// should not mean scrolling past the byte layout that feeds them.

import Foundation
@testable import SwiftMail

extension MSGParserTests {

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
        rtf: Data? = MSGParserTests.encapsulatedHTML,
        leadingFreeSlots: Int = 0
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

        return CompoundFileBuilder.build(
            root: mapiNodes(properties, isTopLevel: true, extra: children),
            leadingFreeSlots: leadingFreeSlots
        )
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

    /// Two levels of forwarding: a message inside a message inside this one.
    static func doublyNestedMSG() -> Data {
        let innermost = mapiNodes([
            .unicode(.subject, "Innerste"),
            .unicode(.body, "Innerster Text")
        ], isTopLevel: false)

        let middle = mapiNodes([
            .unicode(.subject, "Mittlere"),
            .unicode(.body, "Mittlerer Text")
        ], isTopLevel: false, extra: [
            .storage(name: "__attach_version1.0_#00000000", children: mapiNodes([
                .int32(.attachMethod, 5)
            ], isTopLevel: false, extra: [
                .storage(name: "__substg1.0_3701000D", children: innermost)
            ]))
        ])

        return CompoundFileBuilder.build(root: mapiNodes([
            .unicode(.subject, "Aussen"),
            .unicode(.body, "Aeusserer Text")
        ], isTopLevel: true, extra: [
            .storage(name: "__attach_version1.0_#00000000", children: mapiNodes([
                .int32(.attachMethod, 5)
            ], isTopLevel: false, extra: [
                .storage(name: "__substg1.0_3701000D", children: middle)
            ]))
        ]))
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
}
