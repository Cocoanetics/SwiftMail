// EMLTests.swift
// Tests for EML parsing and serialization

import Testing
import Foundation
@testable import SwiftMail

@Suite("EML Parser Tests", .tags(.mime), .timeLimit(.minutes(1)))
struct EMLParserTests {

    // MARK: - Simple Plain Text

    @Test("Parse simple plain text message")
    func testParsePlainText() throws {
        let eml = """
        From: sender@example.com\r
        To: recipient@example.com\r
        Subject: Hello World\r
        Date: Mon, 16 Feb 2026 10:30:00 +0100\r
        Message-ID: <test123@example.com>\r
        Content-Type: text/plain; charset=UTF-8\r
        Content-Transfer-Encoding: 7bit\r
        \r
        Hello, this is a test message.\r
        """

        let data = Data(eml.utf8)
        let message = try Message(emlData: data)

        #expect(message.from == "sender@example.com")
        #expect(message.to == ["recipient@example.com"])
        #expect(message.subject == "Hello World")
        #expect(message.header.messageId == MessageID("test123@example.com"))
        #expect(message.date != nil)
        #expect(message.parts.count == 1)
        #expect(message.parts[0].contentType == "text/plain; charset=UTF-8")
        #expect(message.parts[0].encoding == "7bit")
        #expect(message.textBody?.contains("Hello, this is a test message.") == true)
    }

    // MARK: - Multipart Alternative

    @Test("Parse multipart/alternative message")
    func testParseMultipartAlternative() throws {
        let eml = """
        From: sender@example.com\r
        To: recipient@example.com\r
        Subject: Multipart Test\r
        Content-Type: multipart/alternative; boundary="boundary123"\r
        \r
        --boundary123\r
        Content-Type: text/plain; charset=UTF-8\r
        Content-Transfer-Encoding: 7bit\r
        \r
        Plain text version.\r
        --boundary123\r
        Content-Type: text/html; charset=UTF-8\r
        Content-Transfer-Encoding: 7bit\r
        \r
        <html><body>HTML version.</body></html>\r
        --boundary123--\r
        """

        let data = Data(eml.utf8)
        let message = try Message(emlData: data)

        try #require(message.parts.count == 2, "Expected 2 parts, got \(message.parts.count)")
        #expect(message.parts[0].contentType == "text/plain; charset=UTF-8")
        #expect(message.parts[1].contentType == "text/html; charset=UTF-8")
        #expect(message.textBody?.contains("Plain text version.") == true)
        #expect(message.htmlBody?.contains("HTML version.") == true)
    }

    // MARK: - Multipart Mixed with Attachment

    @Test("Parse multipart/mixed with attachment")
    func testParseMultipartMixed() throws {
        let eml = """
        From: sender@example.com\r
        To: recipient@example.com\r
        Subject: With Attachment\r
        Content-Type: multipart/mixed; boundary="outer"\r
        \r
        --outer\r
        Content-Type: text/plain; charset=UTF-8\r
        \r
        Message body here.\r
        --outer\r
        Content-Type: application/pdf; name="report.pdf"\r
        Content-Disposition: attachment; filename="report.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        SGVsbG8gV29ybGQ=\r
        --outer--\r
        """

        let data = Data(eml.utf8)
        let message = try Message(emlData: data)

        try #require(message.parts.count == 2, "Expected 2 parts, got \(message.parts.count): \(message.parts.map { "\($0.section): \($0.contentType)" })")
        #expect(message.parts[1].filename == "report.pdf")
        #expect(message.parts[1].disposition == "attachment")
        #expect(message.parts[1].encoding == "base64")
        #expect(message.attachments.count == 1)
    }

    // MARK: - RFC 2047 Encoded Subject

    @Test("Parse RFC 2047 encoded subject")
    func testRFC2047Subject() throws {
        let eml = """
        From: sender@example.com\r
        To: recipient@example.com\r
        Subject: =?UTF-8?B?VMOkZ2xpY2hlciBCZXJpY2h0?=\r
        Content-Type: text/plain\r
        \r
        Body.\r
        """

        let data = Data(eml.utf8)
        let message = try Message(emlData: data)

        #expect(message.subject == "Täglicher Bericht")
    }

    // MARK: - Address Parsing

    @Test("Parse display name addresses")
    func testAddressParsing() throws {
        let eml = """
        From: "Oliver Drobnik" <oliver@example.com>\r
        To: "Alice" <alice@example.com>, bob@example.com\r
        Subject: Test\r
        Content-Type: text/plain\r
        \r
        Body.\r
        """

        let data = Data(eml.utf8)
        let message = try Message(emlData: data)

        #expect(message.from == "\"Oliver Drobnik\" <oliver@example.com>")
        #expect(message.to.count == 2)
    }

    // MARK: - Date Parsing

    @Test("Parse various date formats")
    func testDateParsing() {
        let formats = [
            "Mon, 16 Feb 2026 10:30:00 +0100",
            "16 Feb 2026 10:30:00 +0100",
            "Mon, 6 Feb 2026 10:30:00 +0100",
        ]

        for format in formats {
            let date = EMLParser.parseRFC2822Date(format)
            #expect(date != nil, "Failed to parse: \(format)")
        }
    }

    // MARK: - Boundary Extraction

    @Test("Extract boundary from Content-Type")
    func testBoundaryExtraction() {
        let ct1 = "multipart/mixed; boundary=\"abc123\""
        #expect(EMLParser.extractBoundary(from: ct1) == "abc123")

        let ct2 = "multipart/alternative; boundary=simple"
        #expect(EMLParser.extractBoundary(from: ct2) == "simple")

        let ct3 = "text/plain; charset=UTF-8"
        #expect(EMLParser.extractBoundary(from: ct3) == nil)
    }
}

@Suite("EML Serializer Tests", .tags(.mime), .timeLimit(.minutes(1)))
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
