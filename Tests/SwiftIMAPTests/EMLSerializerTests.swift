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
