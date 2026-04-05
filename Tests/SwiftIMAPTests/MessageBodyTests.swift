import Testing
import Foundation
import SwiftMail
import NIOIMAP
import NIOIMAPCore
import OrderedCollections

@Test
func testFindHtmlBodyWithCharset() throws {
        // Create a message with HTML content type that includes charset
        let header = MessageInfo(
            sequenceNumber: SequenceNumber(1),
            uid: UID(1),
            subject: "Test Email",
            from: "test@example.com",
            to: ["recipient@example.com"],
            cc: [],
            bcc: ["hidden@example.com"],
            date: Date(),
            flags: []
        )

        let htmlPart = MessagePart(
            section: Section([1]),
            contentType: "text/html; charset=utf-8",
            disposition: nil,
            encoding: "quoted-printable",
            filename: nil,
            contentId: nil,
            data: "<html><body>Test HTML content</body></html>".data(using: .utf8)
        )
        
        let textPart = MessagePart(
            section: Section([2]),
            contentType: "text/plain; charset=utf-8",
            disposition: nil,
            encoding: "quoted-printable",
            filename: nil,
            contentId: nil,
            data: "Test plain text content".data(using: .utf8)
        )
        
        let message = Message(header: header, parts: [htmlPart, textPart])
        
        // Test the new unified API
        let bodies = message.bodies
        #expect(bodies.count == 2)
        
        let htmlBodyPart = message.findHtmlBodyPart()
        #expect(htmlBodyPart != nil)
        #expect(htmlBodyPart?.contentType == "text/html; charset=utf-8")
        
        let textBodyPart = message.findTextBodyPart()
        #expect(textBodyPart != nil)
        #expect(textBodyPart?.contentType == "text/plain; charset=utf-8")
        
        // Test the legacy API (now fixed)
        let htmlBody = message.htmlBody
        #expect(htmlBody != nil)
        #expect(htmlBody?.contains("Test HTML content") == true)
        
        let textBody = message.textBody
        #expect(textBody != nil)
        #expect(textBody?.contains("Test plain text content") == true)

        // Verify BCC recipients are exposed
        #expect(message.bcc == ["hidden@example.com"])
}

@Test
func testFindBodiesExcludesAttachments() throws {
        let header = MessageInfo(
            sequenceNumber: SequenceNumber(1),
            uid: UID(1),
            subject: "Test Email",
            from: "test@example.com",
            to: ["recipient@example.com"],
            cc: [],
            date: Date(),
            flags: []
        )
        
        let htmlPart = MessagePart(
            section: Section([1]),
            contentType: "text/html; charset=utf-8",
            disposition: nil,
            encoding: "quoted-printable",
            filename: nil,
            contentId: nil,
            data: "<html><body>Test HTML content</body></html>".data(using: .utf8)
        )
        
        let attachmentPart = MessagePart(
            section: Section([2]),
            contentType: "text/plain; charset=utf-8",
            disposition: "attachment",
            encoding: "base64",
            filename: "test.txt",
            contentId: nil,
            data: "Test attachment content".data(using: .utf8)
        )
        
        let message = Message(header: header, parts: [htmlPart, attachmentPart])
        
        // Test that attachments are excluded from bodies
        let bodies = message.bodies
        #expect(bodies.count == 1)
        #expect(bodies.first?.contentType == "text/html; charset=utf-8")
        
        // Test that attachments are still found
        let attachments = message.attachments
        #expect(attachments.count == 1)
        #expect(attachments.first?.filename == "test.txt")
}

@Test
func testPartsWithContentIDAreCategorized() throws {
        let header = MessageInfo(
            sequenceNumber: SequenceNumber(1),
            uid: UID(1),
            subject: "Test Email",
            from: "test@example.com",
            to: ["recipient@example.com"],
            cc: [],
            date: Date(),
            flags: []
        )

        let cidPart = MessagePart(
            section: Section([1]),
            contentType: "image/jpeg",
            disposition: nil,
            encoding: "base64",
            filename: "image001.jpg",
            contentId: "image001.jpg@01DC23D1.C00BAD40",
            data: Data()
        )

        let attachmentPart = MessagePart(
            section: Section([2]),
            contentType: "text/plain",
            disposition: "attachment",
            encoding: "base64",
            filename: "file.txt",
            contentId: nil,
            data: Data()
        )

        let message = Message(header: header, parts: [cidPart, attachmentPart])

        let attachments = message.attachments
        #expect(attachments.count == 1)
        #expect(attachments.first?.filename == "file.txt")

        let cids = message.cids
        #expect(cids.count == 1)
        #expect(cids.first?.contentId == "image001.jpg@01DC23D1.C00BAD40")
}

@Test
func testGetTextContentFromPart() throws {
        let htmlPart = MessagePart(
            section: Section([1]),
            contentType: "text/html; charset=utf-8",
            disposition: nil,
            encoding: "quoted-printable",
            filename: nil,
            contentId: nil,
            data: "<html><body>Test HTML content</body></html>".data(using: .utf8)
        )

        // Test the new textContent property
        let content = htmlPart.textContent
        #expect(content != nil)
        #expect(content?.contains("Test HTML content") == true)
}

@Test
func testIso88591QuotedPrintableHtmlPreservesUmlautsForMarkdownConversion() async throws {
        // Body bytes are transfer-encoded quoted-printable text in ISO-8859-1.
        // The ä/ö/ü bytes (E4/F6/FC) must survive transfer decoding before charset decoding.
        let qpHTML = "<html><head><meta charset=\"iso-8859-1\"></head><body><p>Gr=FC=DFe aus K=F6ln: =E4=F6=FC</p></body></html>"
        let htmlPart = MessagePart(
            section: Section([1]),
            contentType: "text/html; charset=iso-8859-1",
            disposition: nil,
            encoding: "quoted-printable",
            filename: nil,
            contentId: nil,
            data: qpHTML.data(using: .ascii)
        )

        guard let transferDecoded = htmlPart.decodedData() else {
            throw TestFailure("Expected transfer-decoded bytes")
        }

        // Ensure bytes are still ISO-8859-1 bytes (not UTF-8 re-encoded).
        #expect(transferDecoded.contains(0xFC), "Expected ISO-8859-1 byte 0xFC (ü)")
        #expect(!transferDecoded.contains(0xC3), "Unexpected UTF-8 lead byte 0xC3 found before charset decode")

        guard let html = htmlPart.textContent else {
            throw TestFailure("Expected textContent after charset decode")
        }

        #expect(html.contains("Grüße aus Köln: äöü"))

        // Real html2md path: hand off bytes + charset to SwiftText HTMLDocument.
        guard let markdown = await htmlPart.markdownContent() else {
            throw TestFailure("Expected markdown from HTML part")
        }

        #expect(markdown.contains("Grüße aus Köln: äöü"))
}

@Test
func testMarkdownContentSanitizesUnicodeAbuse() async throws {
    // Build an HTML part whose text body contains Unicode-abuse patterns:
    //   - A cluster with many stacked combining marks (zalgo-style)
    //   - A bidi override character (U+202E RIGHT-TO-LEFT OVERRIDE)
    // After markdownContent() both must be stripped by UnicodeAbuseSanitizer.
    let zalgo = "e\u{0300}\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}\u{0306}\u{0307}\u{0308}\u{0309}\u{030A}\u{030B}\u{030C}\u{030D}\u{030E}\u{030F}\u{0310}" // 17 combining marks on 'e'
    let bidiAbuse = "safe\u{202E}esrever"   // RTL override mid-text
    let html = "<html><body><p>\(zalgo)</p><p>\(bidiAbuse)</p></body></html>"

    let htmlPart = MessagePart(
        section: Section([1]),
        contentType: "text/html; charset=utf-8",
        disposition: nil,
        encoding: "8bit",
        filename: nil,
        contentId: nil,
        data: html.data(using: .utf8)
    )

    guard let markdown = await htmlPart.markdownContent() else {
        throw TestFailure("Expected markdown output")
    }

    // The bidi override scalar U+202E must have been removed.
    #expect(!markdown.unicodeScalars.contains(where: { $0.value == 0x202E }), "Bidi override must be stripped")

    // The 'e' with 17 combining marks must be reduced: the base character survives,
    // but the excessive combining marks are trimmed (only ≤ 15 kept).
    let maxCluster = markdown.map { String($0).unicodeScalars.count }.max() ?? 0
    #expect(maxCluster <= 16, "No grapheme cluster should exceed 16 scalars after sanitization")
}

@Test
func testMarkdownConversionFallsBackWhenCharsetIsUnknown() async throws {
        let html = "<html><body><p>Grüße aus Köln: äöü</p></body></html>"
        let htmlPart = MessagePart(
            section: Section([1]),
            contentType: "text/html; charset=x-unknown-charset",
            disposition: nil,
            encoding: "8bit",
            filename: nil,
            contentId: nil,
            data: html.data(using: .utf8)
        )

        guard let markdown = await htmlPart.markdownContent() else {
            throw TestFailure("Expected markdown with unknown charset fallback")
        }

        #expect(markdown.contains("Grüße aus Köln: äöü"))
}

@Test
func testDecodesMIMEEncodedAttachmentFilename() throws {
        let encodedName = "=?utf-8?Q?HC=5F1161254447.pdf?="
        var params = OrderedDictionary<String, String>()
        params["filename"] = encodedName
        let fields = BodyStructure.Fields(
            parameters: params,
            id: nil,
            contentDescription: nil,
            encoding: .base64,
            octetCount: 0
        )
        let single = BodyStructure.Singlepart(
            kind: .basic(.init(topLevel: "application", sub: "pdf")),
            fields: fields,
            extension: nil
        )
        let structure = BodyStructure.singlepart(single)

        let parts = Array<MessagePart>(structure)
        #expect(parts.count == 1)
        #expect(parts.first?.filename == "HC_1161254447.pdf")
        #expect(parts.first?.suggestedFilename == "HC_1161254447.pdf")
}

@Test
func testUsesNameParameterForFilename() throws {
        var params = OrderedDictionary<String, String>()
        params["name"] = "image001.jpg"
        let fields = BodyStructure.Fields(
            parameters: params,
            id: "image001.jpg@cid",
            contentDescription: nil,
            encoding: .base64,
            octetCount: 0
        )
        let single = BodyStructure.Singlepart(
            kind: .basic(.init(topLevel: "image", sub: "jpeg")),
            fields: fields,
            extension: nil
        )
        let structure = BodyStructure.singlepart(single)

        let parts = Array<MessagePart>(structure)
        #expect(parts.count == 1)
        #expect(parts.first?.filename == "image001.jpg")
        #expect(parts.first?.contentId == "image001.jpg@cid")
}

@Test
func testFetchMessagesSequentialOrder() async throws {
        final class FakeServer {
            var callOrder: [String] = []

            func fetchMessageInfo<T: SwiftMail.MessageIdentifier>(for identifier: T) async throws -> MessageInfo? {
                callOrder.append("info")
                return MessageInfo(
                    sequenceNumber: SwiftMail.SequenceNumber(1),
                    uid: SwiftMail.UID(1),
                    subject: nil,
                    from: nil,
                    to: [],
                    cc: [],
                    date: Date(),
                    flags: []
                )
            }

            func fetchMessage(from header: MessageInfo) async throws -> Message {
                callOrder.append("message")
                return Message(header: header, parts: [])
            }

            nonisolated func fetchMessages<T: SwiftMail.MessageIdentifier>(using identifierSet: SwiftMail.MessageIdentifierSet<T>) -> AsyncThrowingStream<Message, Error> {
                AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            guard !identifierSet.isEmpty else {
                                throw IMAPError.emptyIdentifierSet
                            }

                            for identifier in identifierSet.toArray() {
                                try Task.checkCancellation()
                                if let header = try await fetchMessageInfo(for: identifier) {
                                    let email = try await fetchMessage(from: header)
                                    continuation.yield(email)
                                }
                            }

                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }

                    continuation.onTermination = { @Sendable _ in
                        task.cancel()
                    }
                }
            }
        }

        let server = FakeServer()
        let set = SwiftMail.MessageIdentifierSet<SwiftMail.SequenceNumber>([SwiftMail.SequenceNumber(1), SwiftMail.SequenceNumber(2)])
        var messages: [Message] = []
        for try await message in server.fetchMessages(using: set) {
            messages.append(message)
        }

        #expect(messages.count == 2)
        #expect(server.callOrder == ["info", "message", "info", "message"])
}
