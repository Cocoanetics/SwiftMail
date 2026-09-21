// MSGRTFTests.swift
// Tests for the two decoders a .msg body needs: LZFu decompression
// (MS-OXRTFCP) and HTML de-encapsulation (MS-OXRTFEX).

import Testing
import Foundation
@testable import SwiftMail

@Suite("MSG RTF Body Decoding", .tags(.mime, .decoding), .timeLimit(.minutes(1)))
struct MSGRTFTests {

    // MARK: - Helpers

    /// Build a `PR_RTF_COMPRESSED` stream from a list of tokens.
    ///
    /// The compressor Outlook uses is not needed to test the decompressor: a
    /// stream of literals plus back-references, terminated by the
    /// offset-equals-write-position marker, is valid LZFu by construction.
    enum Token {
        case literal(UInt8)
        /// A copy of `length` bytes from `offset` in the ring dictionary.
        case reference(offset: Int, length: Int)
    }

    static func compress(_ tokens: [Token], uncompressedSize: Int) -> Data {
        var payload: [UInt8] = []
        var writePosition = RTFCompression.initialDictionary.count

        // Tokens are emitted in groups of eight, each group preceded by the
        // control byte whose bits say which of them are back-references.
        var index = 0
        while index < tokens.count {
            let group = Array(tokens[index..<min(index + 8, tokens.count)])
            var control: UInt8 = 0
            var body: [UInt8] = []
            for (bit, token) in group.enumerated() {
                switch token {
                    case .literal(let byte):
                        body.append(byte)
                        writePosition = (writePosition + 1) % 4096
                    case .reference(let offset, let length):
                        control |= UInt8(1 << bit)
                        body.append(UInt8((offset >> 4) & 0xFF))
                        body.append(UInt8(((offset & 0x0F) << 4) | ((length - 2) & 0x0F)))
                        writePosition = (writePosition + length) % 4096
                }
            }
            payload.append(control)
            payload.append(contentsOf: body)
            index += 8
        }

        // End of stream: a back-reference naming the current write position.
        payload.append(0x01)
        payload.append(UInt8((writePosition >> 4) & 0xFF))
        payload.append(UInt8((writePosition & 0x0F) << 4))

        var stream = Data()
        stream.append(contentsOf: uint32(UInt32(payload.count + 12)))  // COMPSIZE: everything after itself
        stream.append(contentsOf: uint32(UInt32(uncompressedSize)))
        stream.append(contentsOf: uint32(0x7546_5A4C))                 // "LZFu"
        stream.append(contentsOf: uint32(0))                           // CRC, unchecked
        stream.append(contentsOf: payload)
        return stream
    }

    static func uint32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    // MARK: - LZFu

    @Test("Preloaded dictionary is the 207 bytes both sides agree on")
    func testInitialDictionarySize() {
        #expect(RTFCompression.initialDictionary.count == 207)
        #expect((String(bytes: RTFCompression.initialDictionary, encoding: .ascii) ?? "").hasPrefix("{\\rtf1\\ansi"))
    }

    @Test("Literal-only stream decompresses to its bytes")
    func testDecompressLiterals() throws {
        let text = Array("{\\rtf1 hello}".utf8)
        let stream = Self.compress(text.map { .literal($0) }, uncompressedSize: text.count)

        let result = try RTFCompression.decompress(stream)
        #expect(Array(result) == text)
    }

    @Test("Back-reference reads the preloaded dictionary")
    func testDecompressDictionaryReference() throws {
        // Offset 0, length 11 is "{\rtf1\ansi" — present in the dictionary
        // before a single byte of this stream has been output.
        let stream = Self.compress([.reference(offset: 0, length: 11)], uncompressedSize: 11)

        let result = try RTFCompression.decompress(stream)
        #expect(String(bytes: result, encoding: .ascii) == "{\\rtf1\\ansi")
    }

    @Test("Back-reference reads bytes this stream just emitted")
    func testDecompressSelfReference() throws {
        let start = RTFCompression.initialDictionary.count
        let tokens: [Token] = Array("abcd".utf8).map { .literal($0) } + [.reference(offset: start, length: 4)]

        let result = try RTFCompression.decompress(Self.compress(tokens, uncompressedSize: 8))
        #expect(String(bytes: result, encoding: .ascii) == "abcdabcd")
    }

    @Test("Uncompressed MELA stream is returned verbatim")
    func testDecompressMELA() throws {
        let body = Array("{\\rtf1\\ansi uncompressed}".utf8)
        var stream = Data()
        stream.append(contentsOf: Self.uint32(UInt32(body.count + 12)))
        stream.append(contentsOf: Self.uint32(UInt32(body.count)))
        stream.append(contentsOf: Self.uint32(0x414C_454D))  // "MELA"
        stream.append(contentsOf: Self.uint32(0))
        stream.append(contentsOf: body)

        #expect(Array(try RTFCompression.decompress(stream)) == body)
    }

    @Test("Unknown compression magic is rejected")
    func testDecompressUnknownMagic() {
        var stream = Data()
        stream.append(contentsOf: Self.uint32(16))
        stream.append(contentsOf: Self.uint32(4))
        stream.append(contentsOf: Self.uint32(0xDEAD_BEEF))
        stream.append(contentsOf: Self.uint32(0))
        stream.append(contentsOf: [0x41, 0x42, 0x43, 0x44])

        #expect(throws: MSGParserError.self) { try RTFCompression.decompress(stream) }
    }

    @Test("Truncated stream yields what survived instead of throwing")
    func testDecompressTruncated() throws {
        let text = Array("abcdefgh".utf8)
        let full = Self.compress(text.map { .literal($0) }, uncompressedSize: text.count)
        // Drop the end marker and the last literal group.
        let truncated = full.prefix(full.count - 4)

        let result = try RTFCompression.decompress(Data(truncated))
        #expect(result.count < text.count)
        #expect(String(bytes: result, encoding: .ascii)?.hasPrefix("abcd") == true)
    }

    // MARK: - Flavour classification

    @Test("Body flavour is read from the leading control words")
    func testFlavourClassification() {
        let html = Data("{\\rtf1\\ansi\\ansicpg1252\\fromhtml1 \\fbidis \\deff0".utf8)
        let text = Data("{\\rtf1\\ansi\\ansicpg1252\\fromtext \\deff0".utf8)
        let rich = Data("{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl}".utf8)

        #expect(RTFDeencapsulation.flavour(of: html) == .encapsulatedHTML)
        #expect(RTFDeencapsulation.flavour(of: text) == .encapsulatedText)
        #expect(RTFDeencapsulation.flavour(of: rich) == .rtf)
    }

    @Test("A \\fromhtml1 mentioned past the header does not reclassify the body")
    func testFlavourIgnoresLateMarker() {
        var rtf = Data("{\\rtf1\\ansi\\deff0 ".utf8)
        rtf.append(Data(repeating: UInt8(ascii: "x"), count: 2000))
        rtf.append(Data("\\fromhtml1".utf8))

        #expect(RTFDeencapsulation.flavour(of: rtf) == .rtf)
    }

    // MARK: - De-encapsulation

    @Test("Tag destinations and unfenced text rebuild the HTML")
    func testDeencapsulateBasic() {
        let rtf = Data(#"""
        {\rtf1\ansi\ansicpg1252\fromhtml1 \deff0{\fonttbl{\f0\fswiss Arial;}}
        {\*\htmltag19 <html>}{\*\htmltag34 <body>}
        \htmlrtf {\f0\fs22 \htmlrtf0 Hello world\htmlrtf\par}\htmlrtf0
        {\*\htmltag42 </body>}{\*\htmltag27 </html>}}
        """#.utf8)

        let html = RTFDeencapsulation.html(from: rtf)
        #expect(html.contains("<html>"))
        #expect(html.contains("<body>"))
        #expect(html.contains("Hello world"))
        #expect(html.contains("</html>"))
        // The font table is RTF bookkeeping and must not reach the output.
        #expect(!html.contains("Arial"))
    }

    @Test("Text between \\htmlrtf fences is dropped")
    func testDeencapsulateSuppression() {
        let rtf = Data(#"{\rtf1\fromhtml1 visible\htmlrtf hidden\htmlrtf0 again}"#.utf8)

        let html = RTFDeencapsulation.html(from: rtf)
        #expect(html.contains("visible"))
        #expect(html.contains("again"))
        #expect(!html.contains("hidden"))
    }

    @Test("A fence opened inside a group closes with that group")
    func testDeencapsulateSuppressionIsGroupScoped() {
        // Without restoring `\htmlrtf` on `}`, "after" would stay suppressed.
        let rtf = Data(#"{\rtf1\fromhtml1 {\htmlrtf hidden}after}"#.utf8)

        let html = RTFDeencapsulation.html(from: rtf)
        #expect(html.contains("after"))
        #expect(!html.contains("hidden"))
    }

    @Test("Code-page escapes decode through \\ansicpg")
    func testDeencapsulateCodePage() {
        // 0xFC is ü in CP1252; 0xA4 is € in CP1252 but ¤ in ISO-8859-1, so the
        // declared page has to be the one that is used.
        let rtf = Data(#"{\rtf1\ansi\ansicpg1252\fromhtml1 Gr\'fc\'dfe}"#.utf8)

        #expect(RTFDeencapsulation.html(from: rtf).contains("Grüße"))
    }

    @Test("Unicode escapes emit the scalar and drop their ASCII fallback")
    func testDeencapsulateUnicodeEscape() {
        let rtf = Data(#"{\rtf1\fromhtml1 \u8364 ? end}"#.utf8)

        let html = RTFDeencapsulation.html(from: rtf)
        #expect(html.contains("€"))
        // The "?" is the fallback for a reader that cannot show the scalar.
        #expect(!html.contains("?"))
    }

    @Test("A negative \\u parameter is a scalar above U+7FFF")
    func testDeencapsulateNegativeUnicodeEscape() {
        // -3585 is 61951 (U+F1FF) written as a signed 16-bit value.
        let rtf = Data(#"{\rtf1\fromhtml1 \u-3585 ?}"#.utf8)

        #expect(RTFDeencapsulation.html(from: rtf).unicodeScalars.contains("\u{F1FF}"))
    }

    @Test("Ignorable destinations are dropped whole, nested groups included")
    func testDeencapsulateSkipsIgnorableDestinations() {
        let rtf = Data(#"{\rtf1\fromhtml1 {\*\generator Microsoft Word{\nested junk}}kept}"#.utf8)

        let html = RTFDeencapsulation.html(from: rtf)
        #expect(html.contains("kept"))
        #expect(!html.contains("Microsoft Word"))
        #expect(!html.contains("junk"))
    }

    @Test("Escaped braces and backslashes survive as literals")
    func testDeencapsulateEscapedLiterals() {
        let rtf = Data(#"{\rtf1\fromhtml1 a\{b\}c\\d}"#.utf8)

        #expect(RTFDeencapsulation.html(from: rtf).contains(#"a{b}c\d"#))
    }
}
