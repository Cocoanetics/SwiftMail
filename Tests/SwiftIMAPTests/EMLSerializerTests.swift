// EMLSerializerTests.swift
// Tests for EML serialization

import Testing
import Foundation
@testable import SwiftMail

@Suite("EML Serializer Tests", .serialized, .tags(.mime), .timeLimit(.minutes(1)))
struct EMLSerializerTests {

    @Test("Serialize and re-parse round trip")
    func testRoundTrip() throws {
        let eml = """
        From: sender@example.com\r
        To: recipient@example.com\r
        Subject: Round Trip\r
        Date: Mon, 16 Feb 2026 10:30:00 +0100\r
        Content-Type: text/plain; charset=UTF-8\r
        Content-Transfer-Encoding: 7bit\r
        \r
        This is the body.\r
        """

        let data = Data(eml.utf8)
        let original = try Message(emlData: data)

        // Serialize
        let serialized = try original.emlData()
        #expect(serialized.count > 0)

        // Re-parse
        let reparsed = try Message(emlData: serialized)

        #expect(reparsed.from == original.from)
        #expect(reparsed.to == original.to)
        #expect(reparsed.subject == original.subject)
        #expect(reparsed.parts.count == original.parts.count)
    }

    @Test("Serialized output contains required headers")
    func testSerializedHeaders() throws {
        let header = MessageInfo(
            sequenceNumber: SequenceNumber(0),
            subject: "Test Subject",
            from: "sender@example.com",
            to: ["recipient@example.com"],
            date: Date()
        )

        let part = MessagePart(
            section: Section([1]),
            contentType: "text/plain",
            encoding: "7bit",
            data: Data("Hello".utf8)
        )

        let message = Message(header: header, parts: [part])
        let serialized = try message.emlData()
        let str = String(data: serialized, encoding: .utf8)!

        #expect(str.contains("From: sender@example.com"))
        #expect(str.contains("To: recipient@example.com"))
        #expect(str.contains("Subject: Test Subject"))
        #expect(str.contains("MIME-Version: 1.0"))
        #expect(str.contains("Content-Type: text/plain"))
    }

    @Test("Nested multipart round trip preserves the part tree")
    func testNestedMultipartRoundTrip() throws {
        let eml = """
        From: sender@example.com\r
        To: recipient@example.com\r
        Subject: Nested\r
        Content-Type: multipart/mixed; boundary="outer"\r
        \r
        --outer\r
        Content-Type: multipart/alternative; boundary="inner"\r
        \r
        --inner\r
        Content-Type: text/plain; charset=UTF-8\r
        Content-Transfer-Encoding: 8bit\r
        \r
        Grüße aus dem Plain-Text-Teil.\r
        --inner\r
        Content-Type: text/html; charset=UTF-8\r
        Content-Transfer-Encoding: 7bit\r
        \r
        <html><body>HTML version.</body></html>\r
        --inner--\r
        --outer\r
        Content-Type: application/pdf; name="report.pdf"\r
        Content-Disposition: attachment; filename="report.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        SGVsbG8gV29ybGQ=\r
        --outer--\r
        """

        let original = try Message(emlData: Data(eml.utf8))
        let originalSections = original.parts.map(\.section)
        try #require(originalSections == [Section([1, 1]), Section([1, 2]), Section([2])])

        // Serializing nested sections used to recurse infinitely (stack overflow).
        let serialized = try original.emlData()
        let reparsed = try Message(emlData: serialized)

        #expect(reparsed.parts.map(\.section) == originalSections)
        #expect(reparsed.parts.map(\.contentType) == original.parts.map(\.contentType))
        #expect(reparsed.parts.map(\.encoding) == original.parts.map(\.encoding))
        #expect(reparsed.textBody?.contains("Grüße aus dem Plain-Text-Teil.") == true)
        #expect(reparsed.htmlBody?.contains("HTML version.") == true)
        #expect(reparsed.attachments.count == 1)
        #expect(reparsed.attachments.first?.filename == "report.pdf")
    }

    @Test("Singleton nested multipart wrapper survives the round trip")
    func testSingletonNestedMultipartRoundTrip() throws {
        // The wrapper at [1.2] contains a single child [1.2.1]; serialization
        // must keep that MIME level instead of flattening the child to [1.2].
        let eml = """
        From: sender@example.com\r
        To: recipient@example.com\r
        Subject: Singleton Wrapper\r
        Content-Type: multipart/mixed; boundary="outer"\r
        \r
        --outer\r
        Content-Type: multipart/alternative; boundary="middle"\r
        \r
        --middle\r
        Content-Type: text/plain; charset=UTF-8\r
        Content-Transfer-Encoding: 7bit\r
        \r
        Plain text version.\r
        --middle\r
        Content-Type: multipart/related; boundary="inner"\r
        \r
        --inner\r
        Content-Type: text/html; charset=UTF-8\r
        Content-Transfer-Encoding: 7bit\r
        \r
        <html><body>HTML version.</body></html>\r
        --inner--\r
        --middle--\r
        --outer\r
        Content-Type: application/pdf; name="report.pdf"\r
        Content-Disposition: attachment; filename="report.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        SGVsbG8gV29ybGQ=\r
        --outer--\r
        """

        let original = try Message(emlData: Data(eml.utf8))
        let originalSections = original.parts.map(\.section)
        try #require(originalSections == [Section([1, 1]), Section([1, 2, 1]), Section([2])])

        let serialized = try original.emlData()
        let reparsed = try Message(emlData: serialized)

        #expect(reparsed.parts.map(\.section) == originalSections)
        #expect(reparsed.parts.map(\.contentType) == original.parts.map(\.contentType))
        #expect(reparsed.htmlBody?.contains("HTML version.") == true)
        #expect(reparsed.attachments.first?.filename == "report.pdf")
    }

    @Test("Multipart serialization includes boundaries")
    func testMultipartSerialization() throws {
        let header = MessageInfo(
            sequenceNumber: SequenceNumber(0),
            subject: "Multi",
            from: "sender@example.com"
        )

        let textPart = MessagePart(
            section: Section([1]),
            contentType: "text/plain",
            encoding: "7bit",
            data: Data("Plain text".utf8)
        )

        let htmlPart = MessagePart(
            section: Section([2]),
            contentType: "text/html",
            encoding: "7bit",
            data: Data("<p>HTML</p>".utf8)
        )

        let message = Message(header: header, parts: [textPart, htmlPart])
        let serialized = try message.emlData()
        let str = String(data: serialized, encoding: .utf8)!

        #expect(str.contains("multipart/"))
        #expect(str.contains("boundary="))
        #expect(str.contains("Plain text"))
        #expect(str.contains("<p>HTML</p>"))
    }
}

/// MIME parameter and field-body serialization in ``EMLSerializer``. Every
/// assertion is made on the serialized bytes, or on what ``EMLParser`` recovers
/// from them.
@Suite("EML Serializer parameter encoding", .serialized, .tags(.mime), .timeLimit(.minutes(1)))
struct EMLSerializerParameterEncodingTests {

    private static func message(
        contentType: String = "application/pdf",
        disposition: String? = "attachment",
        filename: String?,
        contentId: String? = nil
    ) -> Message {
        let header = MessageInfo(
            sequenceNumber: SequenceNumber(0),
            subject: "Parameters",
            from: "sender@example.com",
            to: ["recipient@example.com"]
        )
        let part = MessagePart(
            section: Section([1]),
            contentType: contentType,
            disposition: disposition,
            encoding: "base64",
            filename: filename,
            contentId: contentId,
            data: Data("cGF5bG9hZA==".utf8)
        )
        return Message(header: header, parts: [part])
    }

    @Test("A quote in a part filename cannot forge a second parameter")
    func filenameQuoteCannotForgeAParameter() throws {
        let filename = #"a"; boundary="X.pdf"#
        let reparsed = try Message(emlData: Self.message(filename: filename).emlData())

        #expect(reparsed.parts.compactMap { $0.filename } == [filename])
    }

    @Test("A hostile part filename is emitted in exactly one spelling")
    func hostileFilenameHasExactlyOneSpelling() throws {
        let data = try Self.message(filename: #"a"; boundary="X.pdf"#).emlData()
        let text = String(data: data, encoding: .utf8)!

        // The extended spelling on both the Content-Type `name` and the
        // Content-Disposition `filename`, and the literal spelling on neither:
        // a receiver is never handed two candidate values to choose between.
        #expect(text.contains(#"; name*=UTF-8''a%22%3B%20boundary%3D%22X.pdf"#))
        #expect(text.contains(#"; filename*=UTF-8''a%22%3B%20boundary%3D%22X.pdf"#))
        #expect(!text.contains(#"name=""#))
        #expect(!text.contains(#"filename=""#))
    }

    @Test("A backslash in a part filename cannot start a quoted-pair")
    func backslashInFilenameIsEncoded() throws {
        let filename = #"report\final.pdf"#
        let data = try Self.message(filename: filename).emlData()
        let text = String(data: data, encoding: .utf8)!

        #expect(text.contains(#"; filename*=UTF-8''report%5Cfinal.pdf"#))
        #expect(!text.contains(#"filename=""#))
        #expect(try Message(emlData: data).parts.compactMap { $0.filename } == [filename])
    }

    @Test("A semicolon in a part filename does not corrupt the stored content type")
    func semicolonInFilenameDoesNotCorruptTheContentType() throws {
        let filename = "a;b.pdf"
        let data = try Self.message(filename: filename).emlData()
        let text = String(data: data, encoding: .utf8)!
        let reparsed = try Message(emlData: data)

        // A `;` is legal between the quotes, so it stays literal on the wire —
        // and the parameter it sits in is still one parameter on the way back.
        #expect(text.contains(#"; name="a;b.pdf""#))
        #expect(reparsed.parts.compactMap { $0.filename } == [filename])
        #expect(reparsed.parts.map { $0.contentType } == ["application/pdf"])
    }

    @Test("A non-ASCII part filename does not put 8-bit octets in a header")
    func nonASCIIFilenameStaysSevenBit() throws {
        let filename = "발표자료.pdf"
        let data = try Self.message(filename: filename).emlData()
        let text = String(data: data, encoding: .utf8)!

        #expect(text.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(try Message(emlData: data).parts.compactMap { $0.filename } == [filename])
    }

    @Test("An ordinary part filename is emitted exactly as before")
    func ordinaryFilenameIsByteIdentical() throws {
        let data = try Self.message(filename: "report.pdf").emlData()
        let text = String(data: data, encoding: .utf8)!

        #expect(text.contains(#"Content-Type: application/pdf; name="report.pdf""#))
        #expect(text.contains(#"Content-Disposition: attachment; filename="report.pdf""#))
        #expect(try Message(emlData: data).parts.compactMap { $0.filename } == ["report.pdf"])
    }

    @Test("A CRLF in a part content type cannot open a second header field")
    func contentTypeCannotInjectAHeaderField() throws {
        let message = Self.message(
            contentType: "application/pdf\r\nBcc: attacker@example.com",
            filename: "report.pdf"
        )
        let lines = String(data: try message.emlData(), encoding: .utf8)!.components(separatedBy: "\r\n")

        #expect(!lines.contains { $0.lowercased().hasPrefix("bcc:") })
        #expect(lines.filter { $0.lowercased().hasPrefix("content-type:") }.count == 1)
    }

    @Test("A CRLF in a part Content-ID cannot open a second header field")
    func contentIdCannotInjectAHeaderField() throws {
        let message = Self.message(
            filename: "logo.png",
            contentId: "logo@example.com>\r\nBcc: attacker@example.com"
        )
        let lines = String(data: try message.emlData(), encoding: .utf8)!.components(separatedBy: "\r\n")

        #expect(!lines.contains { $0.lowercased().hasPrefix("bcc:") })
        #expect(lines.filter { $0.hasPrefix("Content-ID: ") }.count == 1)
    }

    @Test("A CRLF in a part disposition cannot open a second header field")
    func dispositionCannotInjectAHeaderField() throws {
        let message = Self.message(
            disposition: "attachment\r\nBcc: attacker@example.com",
            filename: "report.pdf"
        )
        let lines = String(data: try message.emlData(), encoding: .utf8)!.components(separatedBy: "\r\n")

        #expect(!lines.contains { $0.lowercased().hasPrefix("bcc:") })
        #expect(lines.filter { $0.lowercased().hasPrefix("content-disposition:") }.count == 1)
    }

    @Test("A literal quote in a part filename round-trips through the extended form")
    func embeddedQuoteFilenameRoundTrips() throws {
        // The serializer never emits an RFC 2045 quoted-pair — a `"` is not safe
        // in a quoted-string, so the name is written `name*=`/`filename*=` — and
        // the parser recovers the literal quote, so the library reads back its
        // own output without the reader's quoted-pair path ever being exercised.
        let filename = #"a"b.pdf"#
        let data = try Self.message(filename: filename).emlData()
        let text = String(data: data, encoding: .utf8)!

        #expect(text.contains(#"; filename*=UTF-8''a%22b.pdf"#))
        #expect(!text.contains(#"filename=""#))
        #expect(try Message(emlData: data).parts.compactMap { $0.filename } == [filename])
    }
}
