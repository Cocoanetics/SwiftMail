// EMLByteLevelTests.swift
// Tests for byte-level EML structure parsing: non-UTF-8 and binary part
// content, boundary matching, and header/body split offsets.

import Testing
import Foundation
@testable import SwiftMail

@Suite("EML Byte-Level Structure Tests", .serialized, .tags(.mime), .timeLimit(.minutes(1)))
struct EMLByteLevelTests {

    @Test("Preserve non-UTF-8 8bit part inside multipart")
    func testParseNonUTF8PartInMultipart() throws {
        let latin1Body = Data([0x63, 0x61, 0x66, 0xE9]) // "café" in ISO-8859-1
        var data = Data([
            "From: sender@example.com",
            "To: recipient@example.com",
            "Subject: Mixed Charsets",
            "Content-Type: multipart/mixed; boundary=\"outer\"",
            "",
            "--outer",
            "Content-Type: text/plain; charset=iso-8859-1",
            "Content-Transfer-Encoding: 8bit",
            "",
            ""
        ].joined(separator: "\r\n").utf8)
        data.append(latin1Body)
        data.append(Data([
            "",
            "--outer",
            "Content-Type: text/plain; charset=UTF-8",
            "",
            "ASCII part.",
            "--outer--",
            ""
        ].joined(separator: "\r\n").utf8))

        let message = try Message(emlData: data)

        try #require(message.parts.count == 2, "Expected 2 parts, got \(message.parts.count)")
        #expect(message.parts[0].data == latin1Body)
        #expect(message.parts[0].textContent == "café")
        #expect(message.parts[1].textContent?.contains("ASCII part.") == true)
    }

    @Test("Preserve opaque binary part inside multipart")
    func testParseBinaryPartInMultipart() throws {
        let binaryBody = Data([0x00, 0x01, 0xFF, 0xFE, 0x80, 0x0A, 0xC3, 0x28])
        var data = Data([
            "From: sender@example.com",
            "To: recipient@example.com",
            "Subject: Binary Part",
            "Content-Type: multipart/mixed; boundary=\"outer\"",
            "",
            "--outer",
            "Content-Type: application/octet-stream",
            "Content-Transfer-Encoding: binary",
            "Content-Disposition: attachment; filename=\"blob.bin\"",
            "",
            ""
        ].joined(separator: "\r\n").utf8)
        data.append(binaryBody)
        data.append(Data([
            "",
            "--outer--",
            ""
        ].joined(separator: "\r\n").utf8))

        let message = try Message(emlData: data)

        try #require(message.parts.count == 1, "Expected 1 part, got \(message.parts.count)")
        #expect(message.parts[0].data == binaryBody)
        #expect(message.parts[0].decodedData() == binaryBody)
    }

    @Test("Boundary text inside part content does not split")
    func testBoundaryTextInsideContent() throws {
        let eml = """
        From: sender@example.com\r
        Subject: Boundary In Content\r
        Content-Type: multipart/mixed; boundary="outer"\r
        \r
        --outer\r
        Content-Type: text/plain\r
        \r
        This line mentions --outer mid-line.\r
        --outerspace is a longer token at line start.\r
        Both belong to the same part.\r
        --outer--\r
        """

        let message = try Message(emlData: Data(eml.utf8))

        try #require(message.parts.count == 1, "Expected 1 part, got \(message.parts.count)")
        let text = try #require(message.parts[0].textContent)
        #expect(text.contains("mentions --outer mid-line."))
        #expect(text.contains("--outerspace is a longer token"))
        #expect(text.contains("Both belong to the same part."))
    }

    @Test("Parse LF-only multipart message")
    func testParseLFOnlyMultipart() throws {
        let eml = """
        From: sender@example.com
        Subject: LF Only
        Content-Type: multipart/alternative; boundary="b1"

        --b1
        Content-Type: text/plain

        Plain version.
        --b1
        Content-Type: text/html

        <p>HTML version.</p>
        --b1--
        """

        let message = try Message(emlData: Data(eml.utf8))

        try #require(message.parts.count == 2, "Expected 2 parts, got \(message.parts.count)")
        #expect(message.textBody?.contains("Plain version.") == true)
        #expect(message.htmlBody?.contains("HTML version.") == true)
    }

    @Test("Earliest blank line wins with mixed line endings")
    func testMixedLineEndingSplit() throws {
        // LF-terminated headers; the body itself contains a CRLF blank line.
        // The header/body split must happen at the first blank line, not at
        // the first CRLF-flavored one.
        let eml = "From: sender@example.com\nSubject: Mixed EOL\nContent-Type: text/plain\n\nline one\r\n\r\nline two"

        let message = try Message(emlData: Data(eml.utf8))

        #expect(message.subject == "Mixed EOL")
        try #require(message.parts.count == 1)
        #expect(message.parts[0].textContent == "line one\r\n\r\nline two")
    }

    @Test("Headerless body part defaults to text/plain")
    func testHeaderlessPart() throws {
        let eml = """
        From: sender@example.com\r
        Subject: Headerless Part\r
        Content-Type: multipart/mixed; boundary="outer"\r
        \r
        --outer\r
        \r
        A part with no headers at all.\r
        --outer--\r
        """

        let message = try Message(emlData: Data(eml.utf8))

        try #require(message.parts.count == 1, "Expected 1 part, got \(message.parts.count)")
        #expect(message.parts[0].contentType == "text/plain")
        #expect(message.parts[0].textContent == "A part with no headers at all.")
    }

    @Test("Preamble and epilogue are ignored")
    func testPreambleAndEpilogue() throws {
        let eml = """
        From: sender@example.com\r
        Subject: Preamble\r
        Content-Type: multipart/mixed; boundary="outer"\r
        \r
        This is the preamble. It should be ignored.\r
        --outer\r
        Content-Type: text/plain\r
        \r
        Actual content.\r
        --outer--\r
        This is the epilogue. It should also be ignored.\r
        """

        let message = try Message(emlData: Data(eml.utf8))

        try #require(message.parts.count == 1, "Expected 1 part, got \(message.parts.count)")
        #expect(message.parts[0].textContent == "Actual content.")
    }

    @Test("Transport padding after boundary delimiter is tolerated")
    func testTransportPadding() throws {
        let eml = "From: sender@example.com\r\n"
            + "Subject: Padding\r\n"
            + "Content-Type: multipart/mixed; boundary=\"outer\"\r\n"
            + "\r\n"
            + "--outer \t \r\n"
            + "Content-Type: text/plain\r\n"
            + "\r\n"
            + "Padded delimiter line.\r\n"
            + "--outer--  \r\n"

        let message = try Message(emlData: Data(eml.utf8))

        try #require(message.parts.count == 1, "Expected 1 part, got \(message.parts.count)")
        #expect(message.parts[0].textContent == "Padded delimiter line.")
    }

    @Test("Preserve 8bit bytes in nested multipart")
    func testNestedMultipartWith8BitPart() throws {
        let latin1Body = Data([0x47, 0x72, 0xFC, 0xDF, 0x65]) // "Grüße" in ISO-8859-1
        var data = Data([
            "From: sender@example.com",
            "Subject: Nested",
            "Content-Type: multipart/mixed; boundary=\"outer\"",
            "",
            "--outer",
            "Content-Type: multipart/alternative; boundary=\"inner\"",
            "",
            "--inner",
            "Content-Type: text/plain; charset=iso-8859-1",
            "Content-Transfer-Encoding: 8bit",
            "",
            ""
        ].joined(separator: "\r\n").utf8)
        data.append(latin1Body)
        data.append(Data([
            "",
            "--inner",
            "Content-Type: text/html; charset=UTF-8",
            "",
            "<p>H\u{00FC}bsch</p>",
            "--inner--",
            "",
            "--outer",
            "Content-Type: application/pdf; name=\"doc.pdf\"",
            "Content-Transfer-Encoding: base64",
            "",
            "SGVsbG8gV29ybGQ=",
            "--outer--",
            ""
        ].joined(separator: "\r\n").utf8))

        let message = try Message(emlData: data)

        try #require(message.parts.count == 3, "Expected 3 parts, got \(message.parts.count)")
        #expect(message.parts[0].section == Section([1, 1]))
        #expect(message.parts[0].data == latin1Body)
        #expect(message.parts[0].textContent == "Grüße")
        #expect(message.parts[1].section == Section([1, 2]))
        #expect(message.parts[1].textContent?.contains("Hübsch") == true)
        #expect(message.parts[2].decodedData() == Data("Hello World".utf8))
    }

    @Test("Overlong boundary is treated as opaque content")
    func testOverlongBoundaryFallsBackToOpaque() throws {
        // RFC 2046 §5.1 caps boundaries at 70 characters; longer ones would
        // also make delimiter scanning quadratic in the message size.
        let boundary = String(repeating: "-", count: 100)
        let body = "--\(boundary)\r\nContent-Type: text/plain\r\n\r\nhi\r\n--\(boundary)--\r\n"
        let eml = "From: sender@example.com\r\nContent-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n\(body)"

        let message = try Message(emlData: Data(eml.utf8))

        try #require(message.parts.count == 1)
        #expect(message.parts[0].contentType == "multipart/mixed")
        #expect(message.parts[0].data == Data(body.utf8))
    }

    @Test("Unrecognizable multipart body is kept as an opaque part")
    func testUnmatchedBoundaryFallsBackToOpaque() throws {
        // The preamble is glued to the first delimiter (no line break), so no
        // opening delimiter is recognizable — the body bytes must survive.
        let body = "pre--b\r\nX\r\n--b--\r\n"
        let eml = "From: sender@example.com\r\nContent-Type: multipart/mixed; boundary=\"b\"\r\n\r\n\(body)"

        let message = try Message(emlData: Data(eml.utf8))

        try #require(message.parts.count == 1)
        #expect(message.parts[0].contentType == "multipart/mixed")
        #expect(message.parts[0].data == Data(body.utf8))
    }
}

@Suite("EML Header Robustness Tests", .serialized, .tags(.mime), .timeLimit(.minutes(1)))
struct EMLHeaderRobustnessTests {

    @Test("Multi-byte UTF-8 headers do not shift body bytes")
    func testMultiByteHeaderOffsets() throws {
        // Raw UTF-8 header text (RFC 6532): every non-ASCII character makes
        // character counts diverge from byte offsets.
        let eml = """
        From: Grüße <sender@example.com>\r
        Subject: Übung macht den Meister — äöü\r
        Content-Type: multipart/mixed; boundary="outer"\r
        \r
        --outer\r
        Content-Type: application/pdf; name="report.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        SGVsbG8gV29ybGQ=\r
        --outer--\r
        """

        let message = try Message(emlData: Data(eml.utf8))

        #expect(message.subject == "Übung macht den Meister — äöü")
        try #require(message.parts.count == 1)
        #expect(message.parts[0].decodedData() == Data("Hello World".utf8))
    }

    @Test("Latin-1 header bytes fall back without losing the message")
    func testLatin1HeaderFallback() throws {
        var data = Data("From: sender@example.com\r\nSubject: ".utf8)
        data.append(Data([0x47, 0x72, 0xFC, 0xDF, 0x65])) // "Grüße" in ISO-8859-1
        data.append(Data("\r\nContent-Type: text/plain\r\n\r\nBody text.\r\n".utf8))

        let message = try Message(emlData: data)

        #expect(message.subject == "Grüße")
        try #require(message.parts.count == 1)
        #expect(message.parts[0].textContent?.contains("Body text.") == true)
    }

    @Test("Stray leading line breaks are skipped")
    func testLeadingLineBreaks() throws {
        let eml = "\r\n\nFrom: sender@example.com\r\nSubject: Leading\r\n\r\nBody.\r\n"

        let message = try Message(emlData: Data(eml.utf8))

        #expect(message.subject == "Leading")
        #expect(message.parts.first?.textContent?.contains("Body.") == true)
    }

    @Test("Control characters in header values stay header text")
    func testControlCharactersInHeaders() throws {
        // VT (0x0B) and NEL (0x85, via Latin-1 fallback) are not RFC 5322 line
        // breaks; they must not truncate the value or end the header line.
        var data = Data("From: sender@example.com\r\nSubject: a\u{0B}b".utf8)
        data.append(Data([0x85])) // raw NEL byte: invalid UTF-8, Latin-1 fallback
        data.append(Data("c\r\nContent-Type: text/plain\r\n\r\nBody.\r\n".utf8))

        let message = try Message(emlData: data)

        #expect(message.subject == "a\u{0B}b\u{85}c")
        #expect(message.parts.first?.textContent?.contains("Body.") == true)
    }

    @Test("Crafted NEL byte cannot smuggle a header")
    func testNELHeaderSmuggling() throws {
        var data = Data("From: attacker@example.com\r\nContent-Type: text/plain\r\nSubject: Invoice".utf8)
        data.append(Data([0x85]))
        data.append(Data("Content-Type: multipart/mixed; boundary=X\r\n\r\nYOU OWE 1000 EUR\r\n".utf8))
        data.append(Data("--X\r\nContent-Type: text/plain\r\n\r\nharmless\r\n--X--\r\n".utf8))

        let message = try Message(emlData: data)

        // The smuggled Content-Type stays inside the Subject value; the real
        // one wins and the real body text is preserved.
        #expect(message.parts.first?.contentType.hasPrefix("text/plain") == true)
        #expect(message.parts.first?.textContent?.contains("YOU OWE 1000 EUR") == true)
    }

    @Test("One legacy byte does not mangle other UTF-8 headers")
    func testPerLineHeaderDecoding() throws {
        var data = Data("From: sender@example.com\r\nSubject: Grüße\r\nX-Legacy: caf".utf8)
        data.append(Data([0xE9])) // "é" in ISO-8859-1: invalid UTF-8
        data.append(Data("\r\nContent-Type: text/plain\r\n\r\nBody.\r\n".utf8))

        let message = try Message(emlData: data)

        #expect(message.subject == "Grüße")
        #expect(message.header.additionalFields?["x-legacy"] == "café")
    }
}
