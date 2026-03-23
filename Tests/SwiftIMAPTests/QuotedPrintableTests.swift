import Foundation
import Testing
@testable import SwiftMail

// Use existing tag definitions and add new ones
extension Tag {
    @Tag static var encoding: Self
    @Tag static var decoding: Self
    @Tag static var imap: Self
    @Tag static var performance: Self
    @Tag static var mime: Self
    @Tag static var fileHandling: Self
    @Tag static var security: Self
}

@Suite("Quoted-Printable Encoding Tests", .tags(.imap, .encoding, .decoding), .timeLimit(.minutes(1)))
struct QuotedPrintableTests {
    
    // MARK: - Test Resources
    
    func getResourceURL(for name: String, withExtension ext: String) -> URL? {
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
    }
    
    func loadResourceContent(name: String, withExtension ext: String) throws -> String {
        guard let url = getResourceURL(for: name, withExtension: ext) else {
            throw TestFailure("Failed to locate resource: \(name).\(ext)")
        }
        
        do {
            return try String(contentsOf: url)
        } catch {
            throw TestFailure("Failed to load resource content: \(error)")
        }
    }

    func normalizedLF(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Body Encoding Tests

    @Test("Body encoding never maps spaces to underscores", .tags(.encoding))
    func bodyEncodingDoesNotUseUnderscoresForSpaces() {
        let input = "Hello World from SwiftMail"
        let encoded = input.quotedPrintableEncoded()

        #expect(encoded == input)
        #expect(!encoded.contains("_"))
    }

    @Test("Body encoding wraps long lines at 76 chars with soft breaks", .tags(.encoding))
    func bodyEncodingWrapsLongLinesWithSoftBreaks() {
        let input = String(repeating: "A", count: 220)
        let encoded = input.quotedPrintableEncoded()

        #expect(encoded.contains("=\r\n"))

        let physicalLines = encoded.components(separatedBy: "\r\n")
        #expect(physicalLines.count > 1)

        for index in physicalLines.indices {
            let line = physicalLines[index]
            #expect(line.count <= 76)

            if index < physicalLines.count - 1 {
                #expect(line.hasSuffix("="), "Wrapped line should end with soft-break marker '='")
            }
        }
    }

    @Test("Body encoding encodes trailing spaces and tabs", .tags(.encoding))
    func bodyEncodingEncodesTrailingWhitespace() {
        let input = "Line with trailing space \nLine with trailing tab\t\nFinal line with both \t"
        let encoded = input.quotedPrintableEncoded()
        let lines = encoded.components(separatedBy: "\r\n")

        #expect(lines.count == 3)
        #expect(lines[0].hasSuffix("=20"))
        #expect(lines[1].hasSuffix("=09"))
        #expect(lines[2].hasSuffix("=09"))
        #expect(!encoded.contains("_"))
    }

    @Test("UTF-8 body roundtrip through quoted-printable encoding", .tags(.encoding, .decoding))
    func utf8BodyRoundtrip() {
        let original = "Hello café 😀\n日本語とemoji 👍"
        let encoded = original.quotedPrintableEncoded()
        let decoded = encoded.decodeQuotedPrintable()

        #expect(encoded.contains("\r\n"))
        #expect(decoded.map(normalizedLF) == normalizedLF(original))
        #expect(!encoded.contains("_"))
    }
    
    // MARK: - Basic Decoding Tests
    
    @Test("Basic quoted-printable decoding", .tags(.decoding))
    func basicQuotedPrintableDecoding() {
        // Test basic quoted-printable decoding
        let encoded = "Hello=20World"
        #expect(encoded.decodeQuotedPrintable() == "Hello World")
        
        // Test with special characters
        let specialChars = "Special=20characters:=20=3C=3E=2C=2E=3F=2F=3B=27=22=5B=5D=7B=7D"
        #expect(specialChars.decodeQuotedPrintable() == "Special characters: <>,.?/;'\"[]{}") 
        
        // Test with soft line breaks
        let softBreaks = "This is a long line that=\ncontinues on the next line"
        #expect(softBreaks.decodeQuotedPrintable() == "This is a long line thatcontinues on the next line")
        
        // Test with equals sign
        let equalsSign = "3=3D2+1"
        #expect(equalsSign.decodeQuotedPrintable() == "3=2+1")
    }
    
    @Test("Encoding detection", .tags(.encoding))
    func encodingDetection() {
        // Test ISO-8859-1 encoding detection
        let isoContent = "Content-Type: text/plain; charset=iso-8859-1\r\n\r\nThis has special chars: =E4=F6=FC=DF"
        #expect(isoContent.detectCharsetEncoding() == .isoLatin1)
        
        // Test UTF-8 encoding detection
        let utf8Content = "Content-Type: text/plain; charset=utf-8\r\n\r\nThis has UTF-8 chars: =C3=A4=C3=B6=C3=BC=C3=9F"
        #expect(utf8Content.detectCharsetEncoding() == .utf8)
        
        // Test meta tag charset detection
        let htmlContent = "<html><head><meta charset=utf-8></head><body>Test</body></html>"
        #expect(htmlContent.detectCharsetEncoding() == .utf8)
        
        // Test default to UTF-8 when no charset is specified
        let noCharset = "This has no charset specified"
        #expect(noCharset.detectCharsetEncoding() == .utf8)
    }
    
    @Test("Auto-detection decoding", .tags(.decoding))
    func autoDetectionDecoding() {
        // Simple test with basic content
        let basicContent = "Hello=20World"
        #expect(basicContent.decodeQuotedPrintable() == "Hello World")
    }
    
    // MARK: - MIME Header Tests
    
    @Test("MIME header decoding", .tags(.decoding, .mime))
    func mimeHeaderDecoding() {
        // Test Q-encoded header
        let qEncoded = "=?UTF-8?Q?Hello=20World?="
        #expect(qEncoded.decodeMIMEHeader() == "Hello World")

        // Header Q-decoding should still map underscores to spaces
        let qEncodedUnderscore = "=?UTF-8?Q?Hello_World?="
        #expect(qEncodedUnderscore.decodeMIMEHeader() == "Hello World")
        
        // Test B-encoded header
        let bEncoded = "=?UTF-8?B?SGVsbG8gV29ybGQ=?="
        #expect(bEncoded.decodeMIMEHeader() == "Hello World")
        
        // Test mixed encoding - the implementation concatenates without spaces
        let mixed = "=?UTF-8?Q?Hello?= =?UTF-8?B?V29ybGQ=?="
        // The actual implementation joins them without spaces
        #expect(mixed.decodeMIMEHeader().replacingOccurrences(of: " ", with: "") == "HelloWorld")
        
        // Test with different charset
        let isoEncoded = "=?ISO-8859-1?Q?J=F6rg=20M=FCller?="
        #expect(isoEncoded.decodeMIMEHeader() == "Jörg Müller")
    }

    @Test("Real-world subject decoding", .tags(.decoding, .mime))
    func realWorldSubjectDecoding() {
        let raw = "=?UTF-8?Q?=5B_Last_Chance_-_10=25_OFF_=5D_=F0=9F=8E=93_Hot_Deal=3A_Top_On?= =?UTF-8?Q?line_Courses_Starting_at_just_=249_=E2=80=93_Don=E2=80=99t_Miss?= =?UTF-8?Q?_Out?="
        let expected = "[ Last Chance - 10% OFF ] 🎓 Hot Deal: Top Online Courses Starting at just $9 – Don’t Miss Out"
        #expect(raw.decodeMIMEHeader() == expected)
    }
    
    // MARK: - HTML File Tests
    
    @Test("ISO-8859-1 HTML file processing", .tags(.fileHandling))
    func iso8859HTMLFile() throws {
        let content = try loadResourceContent(name: "sample_quoted_printable", withExtension: "html")
        
        // Test that the content was loaded
        #expect(!content.isEmpty, "Content should not be empty")
        
        // Verify charset detection
        #expect(content.detectCharsetEncoding() == .isoLatin1)
        
        // Test basic decoding of a simple string
        let simpleTest = "Hello=20World"
        #expect(simpleTest.decodeQuotedPrintable() == "Hello World")
    }
    
    @Test("UTF-8 HTML file processing", .tags(.fileHandling))
    func utf8HTMLFile() throws {
        let content = try loadResourceContent(name: "sample_quoted_printable_utf8", withExtension: "html")
        
        // Test that the content was loaded
        #expect(!content.isEmpty, "Content should not be empty")
        
        // Verify charset detection
        #expect(content.detectCharsetEncoding() == .utf8)
        
        // Test basic decoding of a simple string
        let simpleTest = "Hello=20World"
        #expect(simpleTest.decodeQuotedPrintable() == "Hello World")
    }
    
    @Test("MIME header file processing", .tags(.fileHandling, .mime))
    func mimeHeaderFile() throws {
        let content = try loadResourceContent(name: "sample_mime_header", withExtension: "txt")
        
        // Split the content into lines
        let lines = content.components(separatedBy: .newlines)
        
        // Test From header
        if let fromLine = lines.first(where: { $0.starts(with: "From:") }) {
            let decoded = fromLine.decodeMIMEHeader()
            #expect(decoded.contains("Oliver Drobnik"), "From header should be decoded correctly")
        } else {
            throw TestFailure("From header not found")
        }
        
        // Test To header
        if let toLine = lines.first(where: { $0.starts(with: "To:") }) {
            let decoded = toLine.decodeMIMEHeader()
            #expect(decoded.contains("Jörg Müller"), "To header should be decoded correctly")
        } else {
            throw TestFailure("To header not found")
        }
        
        // Test Subject header
        if let subjectLine = lines.first(where: { $0.starts(with: "Subject:") }) {
            let decoded = subjectLine.decodeMIMEHeader()
            #expect(decoded.contains("Test of MIME encoded headers 😀"), "Subject header should be decoded correctly")
        } else {
            throw TestFailure("Subject header not found")
        }
    }
    
    // MARK: - Additional Edge Cases
    
    @Test("Edge cases and malformed input", .tags(.decoding, .security))
    func edgeCasesAndMalformedInput() {
        // Test empty string
        #expect("".decodeQuotedPrintable() == "")

        // Test string without encoding
        #expect("Plain text".decodeQuotedPrintable() == "Plain text")

        // Test malformed encoding (incomplete hex) - should return nil for invalid input
        let malformed = "Hello=2World"  // Missing second hex digit
        let result = malformed.decodeQuotedPrintable()
        #expect(result == nil, "Should return nil for malformed input")

        // Test with invalid hex characters - should return nil for invalid input
        let invalidHex = "Hello=ZZ"
        let invalidResult = invalidHex.decodeQuotedPrintable()
        #expect(invalidResult == nil, "Should return nil for invalid hex")

        // Test = followed by only one character (previously crashed with String index out of bounds)
        let equalsOneChar = "Hello=X"
        #expect(equalsOneChar.decodeQuotedPrintable() == nil, "Should return nil for = with only one trailing char")
        #expect(equalsOneChar.decodeQuotedPrintableLossy() == "Hello=X", "Lossy should preserve = with one trailing char")

        // Test = as the very last character
        let trailingEquals = "Hello="
        #expect(trailingEquals.decodeQuotedPrintable() == nil, "Should return nil for trailing =")
        #expect(trailingEquals.decodeQuotedPrintableLossy() == "Hello=", "Lossy should preserve trailing =")

        // Test = at second-to-last position with valid first hex digit
        let equalsOneHex = "Hello=A"
        #expect(equalsOneHex.decodeQuotedPrintable() == nil, "Should return nil for = with only one hex digit")
        #expect(equalsOneHex.decodeQuotedPrintableLossy() == "Hello=A", "Lossy should preserve incomplete hex")
    }

    @Test("Lossy decoding handles invalid sequences", .tags(.decoding))
    func lossyDecodingHandlesInvalidSequences() {
        // This input contains both valid and invalid quoted-printable sequences
        let mixed = "Line1=0D=0ALine2=ZZ"

        // Strict decoding should fail due to the invalid sequence at the end
        #expect(mixed.decodeQuotedPrintable() == nil)

        // Lossy decoding should still decode the valid sequences
        let lossy = mixed.decodeQuotedPrintableLossy()
        #expect(lossy == "Line1\r\nLine2=ZZ")

        // Another example with a trailing '=' which is incomplete
        let trailingEquals = "Hello=0D=0A="
        #expect(trailingEquals.decodeQuotedPrintable() == nil)
        #expect(trailingEquals.decodeQuotedPrintableLossy() == "Hello\r\n=")
    }
    
    @Test("Performance with large content", .tags(.performance, .decoding))
    func performanceWithLargeContent() {
        // Create a large quoted-printable encoded string
        let baseString = "This=20is=20a=20test=20string=20with=20spaces=0D=0A"
        let largeContent = String(repeating: baseString, count: 1000)
        
        // Test that decoding completes without hanging
        let decoded = largeContent.decodeQuotedPrintable()
        #expect(decoded != nil, "Should decode large content successfully")
        #expect(decoded?.contains("This is a test string with spaces") ?? false, "Should contain expected decoded content")
    }
}

// Custom error type for test failures
struct TestFailure: Error, CustomStringConvertible {
    let description: String
    
    init(_ description: String) {
        self.description = description
    }
} 
