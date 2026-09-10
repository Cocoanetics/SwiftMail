// EMLTests.swift
// Tests for EML parsing

import Testing
import Foundation
@testable import SwiftMail

// swiftlint:disable file_length

@Suite("EML Parser Tests", .serialized, .tags(.mime), .timeLimit(.minutes(1)))
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

    @Test("Preserve non-UTF-8 8bit body bytes")
    func testParseNonUTF8Body() throws {
        let headers = [
            "From: sender@example.com",
            "To: recipient@example.com",
            "Subject: ISO-8859-1 Body",
            "Content-Type: text/plain; charset=iso-8859-1",
            "Content-Transfer-Encoding: 8bit",
            "",
            ""
        ].joined(separator: "\r\n")
        let body = Data([0x63, 0x61, 0x66, 0xE9])
        var data = Data(headers.utf8)
        data.append(body)

        let message = try Message(emlData: data)

        #expect(message.parts.count == 1)
        #expect(message.parts[0].data == body)
        #expect(message.parts[0].decodedData() == body)
        #expect(message.parts[0].textContent == "café")
    }

    @Test("Preserve opaque binary body bytes")
    func testParseBinaryBody() throws {
        let headers = [
            "From: sender@example.com",
            "To: recipient@example.com",
            "Subject: Binary Body",
            "Content-Type: application/octet-stream",
            "Content-Transfer-Encoding: binary",
            "",
            ""
        ].joined(separator: "\r\n")
        let body = Data([0x00, 0x7F, 0x80, 0xFF])
        var data = Data(headers.utf8)
        data.append(body)

        let message = try Message(emlData: data)

        #expect(message.parts.count == 1)
        #expect(message.parts[0].data == body)
        #expect(message.parts[0].decodedData() == body)
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

        let partsSummary = message.parts.map { "\($0.section): \($0.contentType)" }
        try #require(
            message.parts.count == 2,
            "Expected 2 parts, got \(message.parts.count): \(partsSummary)"
        )
        #expect(message.parts[1].filename == "report.pdf")
        #expect(message.parts[1].disposition == "attachment")
        #expect(message.parts[1].encoding == "base64")
        #expect(message.attachments.count == 1)
        #expect(message.attachments[0].decodedData() == Data("Hello World".utf8))
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
            "Mon, 6 Feb 2026 10:30:00 +0100"
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

/// Parameter extraction is anchored to parameter boundaries: an attribute is
/// only an attribute where a parameter can start, never inside another
/// parameter's quoted value. A sender chooses those values, so a substring
/// match there is a sender-chosen parse.
@Suite("MIME parameter parsing", .serialized, .tags(.mime), .timeLimit(.minutes(1)))
struct MIMEParameterParsingTests {

    @Test("An attribute inside a quoted value is not a parameter")
    func quotedValueCannotForgeAParameter() {
        // One legal parameter whose value happens to contain `name*=`. Reading
        // that as an extended parameter reports `invoice.pdf"` for a file the
        // sender named `evil.exe …`.
        let header = #"attachment; filename="evil.exe name*=UTF-8''invoice.pdf""#

        #expect(EMLParser.extractFilename(from: header) == #"evil.exe name*=UTF-8''invoice.pdf"#)
    }

    @Test("A boundary inside a quoted value is not the boundary")
    func quotedValueCannotForgeABoundary() {
        let contentType = #"multipart/mixed; name="x boundary=forged"; boundary=real"#

        #expect(EMLParser.extractBoundary(from: contentType) == "real")
    }

    @Test("A combining mark cannot hide the quote that closes a parameter")
    func combiningMarkCannotHideClosingQuote() {
        let contentType = "multipart/mixed; x=\"\u{0301}a; boundary=evil\"; boundary=real"

        #expect(EMLParser.extractBoundary(from: contentType) == "real")
    }

    @Test("A combining mark after an opening quote stays in the value")
    func combiningMarkAfterOpeningQuoteIsRead() {
        let filename = "\u{0301}report.pdf"
        let header = "attachment; filename=\"\(filename)\""

        #expect(EMLParser.extractFilename(from: header) == filename)
    }

    @Test("Quotes and semicolons inside comments are ignored as grammar")
    func commentsCannotHideOrForgeBoundary() throws {
        let contentType = #"multipart/mixed (size 6"; boundary=evil); boundary=outer"#
        let eml = """
        From: sender@example.com\r
        To: recipient@example.com\r
        Content-Type: \(contentType)\r
        \r
        --outer\r
        Content-Type: text/plain\r
        \r
        body\r
        --outer--\r
        """

        #expect(EMLParser.extractBoundary(from: contentType) == "outer")
        let message = try Message(emlData: Data(eml.utf8))
        #expect(message.parts.count == 1)
        #expect(message.textBody?.contains("body") == true)
    }

    @Test("A semicolon inside a quoted filename does not split the content type")
    func semicolonInQuotedValueDoesNotSplitTheContentType() {
        let contentType = #"application/pdf; name="a;b.pdf"; charset=UTF-8"#

        #expect(EMLParser.cleanContentType(contentType) == "application/pdf; charset=UTF-8")
        #expect(EMLParser.extractFilename(from: contentType) == "a;b.pdf")
    }

    @Test("The extended spelling still wins over the literal one")
    func extendedParameterKeepsPrecedence() {
        let header = "attachment; filename=\"fallback.pdf\"; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf"

        #expect(EMLParser.extractFilename(from: header) == "résumé.pdf")
    }

    @Test("An extended parameter with a language tag is decoded")
    func extendedParameterLanguageTagIsDecoded() {
        let contentType = "application/pdf; name=\"fallback.pdf\"; name*=UTF-8'en'r%C3%A9sum%C3%A9.pdf"

        #expect(EMLParser.extractFilename(from: contentType) == "résumé.pdf")
    }

    @Test("Encoded continuation segments are joined before decoding")
    func encodedContinuationsAreDecoded() {
        let contentType = "application/pdf; name*0*=UTF-8''r%C3%A9; name*1*=sum%C3%A9.pdf"

        #expect(EMLParser.extractFilename(from: contentType) == "résumé.pdf")
        #expect(EMLParser.cleanContentType(contentType) == "application/pdf")
    }

    @Test("Mixed encoded and literal continuation segments are preserved")
    func mixedContinuationsAreDecodedBySegment() {
        let contentType = "application/pdf; name*0*=UTF-8''r%C3%A9; name*1=sum%C3%A9.pdf"

        // Without a trailing `*`, the second segment is literal: its percent
        // sequences are filename text, not RFC 2231 encoding.
        #expect(EMLParser.extractFilename(from: contentType) == "résum%C3%A9.pdf")
        #expect(EMLParser.cleanContentType(contentType) == "application/pdf")
    }

    @Test("An extended parameter may leave the charset field blank")
    func extendedParameterWithBlankCharsetIsDecoded() {
        // RFC 2231 §4: "it is perfectly permissible to leave either the
        // character set or language field blank", the `'` delimiters staying.
        let header = "attachment; filename*=''invoice.pdf"

        #expect(EMLParser.extractFilename(from: header) == "invoice.pdf")
    }

    @Test("An extended parameter decodes in any charset the platform names")
    func extendedParameterHonorsPlatformCharsets() {
        #expect(EMLParser.extractFilename(from: "attachment; filename*=windows-1252''invoice.pdf") == "invoice.pdf")
        #expect(EMLParser.extractFilename(from: "attachment; filename*=ISO-8859-1''caf%E9.txt") == "café.txt")
        #if canImport(Darwin)
        // swift-corelibs-foundation names ISO-8859-15 but has no converter for
        // it, so on Linux this value decodes to nil and the literal spelling is
        // used instead; only the Darwin converter set reaches the euro sign.
        #expect(EMLParser.extractFilename(from: "attachment; filename*=iso-8859-15''%A4.txt") == "€.txt")
        #endif
    }

    @Test("An extended parameter in an unknown charset yields the literal spelling")
    func extendedParameterUnknownCharsetFallsBackToLiteral() {
        let header = "attachment; filename=\"fallback.pdf\"; filename*=x-no-such-charset''a.pdf"

        #expect(EMLParser.extractFilename(from: header) == "fallback.pdf")
    }

    @Test("Continuation sections end at the first gap and reject leading zeroes")
    func continuationSectionsAreContiguousDecimals() {
        // RFC 2231 §3: "neither leading zeroes nor gaps in the sequence are
        // allowed" — `*01*` is not section 1, and section 2 is unreachable
        // without it.
        #expect(EMLParser.extractFilename(from: "application/pdf; name*0*=UTF-8''a; name*01*=b; name*2*=c") == "a")
        #expect(EMLParser.extractFilename(from: "application/pdf; name*0*=UTF-8''a; name*2*=c") == "a")
        // The first occurrence of a repeated section stands.
        #expect(EMLParser.extractFilename(from: "application/pdf; name*0*=UTF-8''a; name*1*=b; name*1*=z") == "ab")
    }

    @Test("Reading a parameter with many continuation sections stays linear")
    func manyContinuationSectionsStayLinear() {
        // A sender chooses the section count. Each section used to be found
        // by re-tokenizing the whole header, so 4096 legal sections cost
        // seconds; one pass over the parameters costs milliseconds.
        let sections = 4096
        let header = "attachment; filename*0*=UTF-8''a; "
            + (1..<sections).map { "filename*\($0)*=a" }.joined(separator: "; ")

        let clock = ContinuousClock()
        var filename: String?
        let elapsed = clock.measure {
            filename = EMLParser.extractFilename(from: header)
        }

        #expect(filename == String(repeating: "a", count: sections))
        #expect(elapsed < .seconds(2))
    }

    @Test("An extended name parameter reads back from a Content-Type")
    func extendedNameParameterReadsBack() {
        let contentType = "application/pdf; name*=UTF-8''%EB%B0%9C%ED%91%9C.pdf"

        #expect(EMLParser.extractFilename(from: contentType) == "발표.pdf")
        #expect(EMLParser.cleanContentType(contentType) == "application/pdf")
    }

    @Test("An extended name parameter still outranks a literal one")
    func extendedNameOutranksLiteralName() {
        // RFC 2231 §4, within ONE attribute: where a sender writes both
        // spellings of `name`, the extended one carries the characters the
        // literal one could not.
        let contentType = "application/pdf; name=\"lit.pdf\"; name*=UTF-8''ext.pdf"

        #expect(EMLParser.extractFilename(from: contentType) == "ext.pdf")
    }

    @Test("A literal filename outranks an extended name")
    func literalFilenameOutranksExtendedName() {
        // RFC 2183 §2.3 ranks the ATTRIBUTES: `filename` names the file, `name`
        // is the deprecated Content-Type spelling. RFC 2231 §4 ranks only the
        // two spellings of ONE attribute, so `name*` does not reach past
        // `filename` — it is the deprecated attribute however it is spelled.
        let header = "application/pdf; filename=\"lit.pdf\"; name*=UTF-8''ext.pdf"

        #expect(EMLParser.extractFilename(from: header) == "lit.pdf")
    }

    @Test("A Content-Disposition filename outranks a Content-Type extended name")
    func dispositionFilenameOutranksContentTypeExtendedName() throws {
        // The attribute ranking has to hold across the two headers a part's
        // filename can come from, not only within each of them: resolving the
        // Content-Type to completion first would let its `name*` win over the
        // Content-Disposition's `filename`, reversing RFC 2183 §2.3.
        let filename = try attachmentFilename(
            contentType: "application/pdf; name*=UTF-8''display.pdf",
            disposition: "attachment; filename=\"real.pdf\""
        )

        #expect(filename == "real.pdf")
    }

    @Test("A Content-Disposition filename outranks a Content-Type literal name")
    func dispositionFilenameOutranksContentTypeLiteralName() throws {
        // Same ranking, neither parameter encoded. The two headers normally
        // carry the same value — this library's own serializer writes them that
        // way — so this only decides a part whose headers disagree, and RFC 2183
        // §2.3 says the disagreement is settled by `filename`.
        let filename = try attachmentFilename(
            contentType: "application/pdf; name=\"display.pdf\"",
            disposition: "attachment; filename=\"real.pdf\""
        )

        #expect(filename == "real.pdf")
    }

    // MARK: - RFC 2045 quoted-pairs

    @Test("An escaped quote does not expose a quoted value's interior")
    func escapedQuoteDoesNotExposeInteriorParameter() {
        // `\"` is an escaped quote inside the value, so the quoted-string does
        // not close until the final `"`: `name` is one parameter whose value is
        // the whole literal, and there is no separate `name*` to be read.
        let header = #"attachment; name="a\"; name*=UTF-8''evil.pdf""#

        #expect(EMLParser.extractFilename(from: header) == #"a"; name*=UTF-8''evil.pdf"#)
    }

    @Test("An escaped quote does not expose a forged boundary")
    func escapedQuoteDoesNotExposeForgedBoundary() {
        let contentType = #"multipart/mixed; x="a\"; boundary=evil"; boundary=real"#

        #expect(EMLParser.extractBoundary(from: contentType) == "real")
    }

    @Test("A quoted value's escaped quote is unescaped, not truncated")
    func quotedPairIsUnescaped() {
        // `filename="a\"b.pdf"` is the single value `a"b.pdf`.
        let header = #"attachment; filename="a\"b.pdf""#

        #expect(EMLParser.extractFilename(from: header) == #"a"b.pdf"#)
    }

    @Test("A value with no quoted-pair is returned byte-identically")
    func ordinaryQuotedValueIsUnchanged() {
        #expect(EMLParser.extractFilename(from: #"attachment; filename="report.pdf""#) == "report.pdf")
    }

    /// Parse a two-part multipart/mixed whose second part carries the given
    /// headers, and return that part's resolved filename.
    private func attachmentFilename(contentType: String, disposition: String) throws -> String? {
        let eml = """
        From: sender@example.com\r
        To: recipient@example.com\r
        Subject: Filename precedence\r
        Content-Type: multipart/mixed; boundary="outer"\r
        \r
        --outer\r
        Content-Type: text/plain; charset=UTF-8\r
        \r
        Message body here.\r
        --outer\r
        Content-Type: \(contentType)\r
        Content-Disposition: \(disposition)\r
        Content-Transfer-Encoding: base64\r
        \r
        SGVsbG8gV29ybGQ=\r
        --outer--\r
        """

        let message = try Message(emlData: Data(eml.utf8))

        try #require(message.parts.count == 2, "Expected 2 parts, got \(message.parts.count)")
        return message.parts[1].filename
    }
}

// swiftlint:enable file_length
