// RTFDeencapsulation.swift
// Recover the original HTML from encapsulated RTF (MS-OXRTFEX).
//
// When Outlook converts an HTML message for storage it does not keep the HTML
// part. It rewrites it as RTF that carries the original markup inside
// `\*\htmltag` destinations, with the RTF it added for renderers fenced off by
// `\htmlrtf` … `\htmlrtf0`. De-encapsulation is the inverse: emit the tag
// destinations and the unfenced text, drop everything between the fences, and
// the original HTML comes back.

import Foundation
import SwiftCross

enum RTFDeencapsulation {

    /// Which of the three things a decompressed RTF body can actually be.
    enum Flavour: Equatable {
        /// `\fromhtml1` — HTML wearing RTF control words.
        case encapsulatedHTML
        /// `\fromtext` — plain text wrapped in RTF; `PR_BODY` already has it.
        case encapsulatedText
        /// A genuinely rich-text body, to be passed through untouched.
        case rtf
    }

    /// Classify a decompressed RTF body.
    ///
    /// The marker sits in the document's leading control words, so only the
    /// head is examined — far enough in to clear `\rtf1\ansi\ansicpgNNNN` and
    /// any `\fbidis`, but not so far that a `\fromhtml1` mentioned in body text
    /// could be mistaken for the real one.
    static func flavour(of rtf: Data) -> Flavour {
        let head = rtf.prefix(1024)
        if head.range(of: Data("\\fromhtml1".utf8)) != nil { return .encapsulatedHTML }
        if head.range(of: Data("\\fromtext".utf8)) != nil { return .encapsulatedText }
        return .rtf
    }

    /// De-encapsulate an RTF body into the HTML it was made from.
    static func html(from rtf: Data) -> String {
        var parser = Parser(bytes: [UInt8](rtf))
        return parser.run()
    }

    /// Destinations whose contents are RTF bookkeeping, never message content.
    /// Their whole group is dropped, brace-matched, so nested groups inside a
    /// font or stylesheet table cannot leak a stray name into the output.
    fileprivate static let skippedDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "listtable", "listoverridetable",
        "info", "pntext", "pntxta", "pntxtb", "filetbl", "revtbl", "rsidtbl",
        "generator", "themedata", "datastore", "latentstyles", "xmlnstbl",
        "upr", "objdata", "nonshppict", "shppict", "pict", "bkmkstart",
        "bkmkend", "colorschememapping", "mmathPr", "wgrffmtfilter"
    ]

    /// IANA names for the `\ansicpg` code pages worth mapping; anything else
    /// falls back to CP1252, which is what Outlook assumes.
    private static let codePageNames: [Int: String] = [
        874: "windows-874", 932: "shift_jis", 936: "gbk", 949: "euc-kr",
        950: "big5", 1250: "windows-1250", 1251: "windows-1251",
        1252: "windows-1252", 1253: "windows-1253", 1254: "windows-1254",
        1255: "windows-1255", 1256: "windows-1256", 1257: "windows-1257",
        1258: "windows-1258", 10000: "macintosh", 28591: "iso-8859-1",
        28592: "iso-8859-2", 28595: "iso-8859-5", 28597: "iso-8859-7",
        28599: "iso-8859-9", 28605: "iso-8859-15"
    ]

    /// Map an RTF `\ansicpg` code page onto a text encoding.
    static func encoding(forCodePage codePage: Int) -> String.Encoding {
        if codePage == 65001 { return .utf8 }
        guard let name = codePageNames[codePage] else { return .windowsCP1252 }
        return String.Encoding(ianaCharsetName: name) ?? .windowsCP1252
    }
}

// MARK: - Parser

private extension RTFDeencapsulation {

    /// A control word and its optional signed parameter.
    struct ControlWord {
        let name: String
        let parameter: Int?
    }

    /// Per-group state. RTF scopes formatting to the enclosing group, and
    /// `\htmlrtf` behaves like a formatting property, so a `}` must restore the
    /// suppression state the group inherited — otherwise a fence opened inside
    /// a group would swallow the rest of the document.
    struct GroupState {
        var suppressed = false
        var skipping = false
        var unicodeSkip = 1
    }

    struct Parser {
        let bytes: [UInt8]
        var index = 0

        var output = String.UnicodeScalarView()
        /// Literal text and `\'hh` escapes are bytes in the document's code
        /// page, which may be multi-byte (Shift-JIS and friends). They are
        /// buffered and decoded as a run so a lead byte and its trail byte are
        /// never decoded apart.
        var pending: [UInt8] = []
        var encoding = String.Encoding.windowsCP1252

        var state = GroupState()
        var stack: [GroupState] = []
        /// Characters still to drop as the ASCII fallback that accompanies a
        /// `\uN` escape.
        var unicodeFallbackRemaining = 0
        /// A high surrogate awaiting its partner. `\uN` carries a signed
        /// 16-bit value, so anything above the BMP arrives as a UTF-16
        /// surrogate pair written as two escapes.
        var pendingHighSurrogate: UInt32?

        var isVisible: Bool { !state.skipping && !state.suppressed }

        mutating func run() -> String {
            while index < bytes.count {
                switch bytes[index] {
                    case UInt8(ascii: "{"):
                        stack.append(state)
                        index += 1
                        unicodeFallbackRemaining = 0
                    case UInt8(ascii: "}"):
                        flush()
                        if let restored = stack.popLast() { state = restored }
                        index += 1
                        unicodeFallbackRemaining = 0
                    case UInt8(ascii: "\\"):
                        consumeEscape()
                    case 0x0D, 0x0A:
                        // Line breaks in the RTF source are formatting, not content.
                        index += 1
                    default:
                        consumeTextByte(bytes[index])
                }
            }
            flush()
            return String(output)
        }

        // MARK: Output

        mutating func flush() {
            guard !pending.isEmpty else { return }
            // Latin-1 maps every byte, so the chain always ends in a string
            // and a bad code page can never drop text on the floor.
            let text = String(bytes: pending, encoding: encoding)
                ?? String(bytes: pending, encoding: .windowsCP1252)
                ?? String(bytes: pending, encoding: .isoLatin1)
                ?? ""
            output.append(contentsOf: text.unicodeScalars)
            pending.removeAll(keepingCapacity: true)
        }

        mutating func append(_ scalar: Unicode.Scalar) {
            guard isVisible else { return }
            flush()
            output.append(scalar)
        }

        /// Buffer one code-page byte, or spend it on a pending `\uN` fallback.
        mutating func appendByte(_ byte: UInt8) {
            if unicodeFallbackRemaining > 0 {
                unicodeFallbackRemaining -= 1
            } else if isVisible {
                pending.append(byte)
            }
        }

        mutating func consumeTextByte(_ byte: UInt8) {
            index += 1
            appendByte(byte)
        }

        // MARK: Escapes

        mutating func consumeEscape() {
            index += 1
            guard index < bytes.count else { return }
            let next = bytes[index]

            if next == UInt8(ascii: "'") {
                consumeHexEscape()
                return
            }
            if next == UInt8(ascii: "\\") || next == UInt8(ascii: "{") || next == UInt8(ascii: "}") {
                index += 1
                appendByte(next)
                return
            }
            if next == UInt8(ascii: "*") {
                consumeIgnorableDestination()
                return
            }

            let word = readControlWord()
            if word.name.isEmpty {
                consumeSymbol()
                return
            }
            // A control word satisfies a pending `\uN` fallback slot.
            if unicodeFallbackRemaining > 0 && word.name != "u" {
                unicodeFallbackRemaining -= 1
                return
            }
            apply(word)
        }

        /// `\'hh` — one byte written in the document's code page.
        mutating func consumeHexEscape() {
            index += 1
            let value = hexByte(at: index)
            index = min(index + 2, bytes.count)
            if let value {
                appendByte(value)
            } else if unicodeFallbackRemaining > 0 {
                unicodeFallbackRemaining -= 1
            }
        }

        /// `\*` — an ignorable destination. Its control word decides whether it
        /// carries the HTML we are after or is dropped whole.
        mutating func consumeIgnorableDestination() {
            index += 1
            // Skip the backslash introducing the destination's word.
            if index < bytes.count && bytes[index] == UInt8(ascii: "\\") { index += 1 }
            let word = readControlWord()

            if word.name == "htmltag" || word.name == "mhtmltag" {
                // The markup this destination holds is the output, and it is
                // emitted whatever fence encloses it.
                state.suppressed = false
            } else {
                state.skipping = true
            }
        }

        /// A lone symbol control such as `\~` (non-breaking space).
        mutating func consumeSymbol() {
            guard index < bytes.count else { return }
            let symbol = bytes[index]
            index += 1

            if unicodeFallbackRemaining > 0 {
                unicodeFallbackRemaining -= 1
            } else if symbol == UInt8(ascii: "~") {
                append(Unicode.Scalar(0x00A0))
            }
        }

        // MARK: Control words

        mutating func apply(_ word: ControlWord) {
            switch word.name {
                case "htmlrtf":
                    // `\htmlrtf` and `\htmlrtf1` open the fence, `\htmlrtf0` closes it.
                    state.suppressed = (word.parameter != 0)
                case "uc":
                    state.unicodeSkip = max(0, word.parameter ?? 1)
                case "ansicpg":
                    encoding = RTFDeencapsulation.encoding(forCodePage: word.parameter ?? 1252)
                case "u":
                    applyUnicodeEscape(word.parameter)
                case "par", "line":
                    append("\n")
                case "tab":
                    append("\t")
                default:
                    if RTFDeencapsulation.skippedDestinations.contains(word.name) { state.skipping = true }
            }
        }

        mutating func applyUnicodeEscape(_ parameter: Int?) {
            defer { unicodeFallbackRemaining = state.unicodeSkip }
            guard let parameter else { return }

            // The parameter is a signed 16-bit value; negatives are code units
            // above U+7FFF written as two's complement.
            let value = parameter < 0 ? parameter + 0x1_0000 : parameter
            let unit = UInt32(truncatingIfNeeded: value)

            // Neither half of a surrogate pair is a scalar on its own, so an
            // emoji arrives as two escapes that must be recombined — taken
            // separately they are both dropped and the character disappears.
            if (0xD800...0xDBFF).contains(unit) {
                pendingHighSurrogate = unit
                return
            }
            if let high = pendingHighSurrogate {
                pendingHighSurrogate = nil
                if (0xDC00...0xDFFF).contains(unit) {
                    let combined = 0x1_0000 + ((high - 0xD800) << 10) + (unit - 0xDC00)
                    if let scalar = Unicode.Scalar(combined) { append(scalar) }
                    return
                }
            }

            guard let scalar = Unicode.Scalar(unit) else { return }
            append(scalar)
        }

        /// Read a control word and its optional signed parameter, leaving
        /// `index` just past the single space that may delimit it.
        mutating func readControlWord() -> ControlWord {
            var letters: [UInt8] = []
            while index < bytes.count, Parser.isASCIILetter(bytes[index]) {
                letters.append(bytes[index])
                index += 1
            }
            guard !letters.isEmpty else { return ControlWord(name: "", parameter: nil) }

            var negative = false
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") {
                negative = true
                index += 1
            }
            var digits: [UInt8] = []
            while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") {
                digits.append(bytes[index])
                index += 1
            }
            // A single trailing space delimits the word and is not content.
            if index < bytes.count, bytes[index] == UInt8(ascii: " ") { index += 1 }

            // Control words and their parameters are ASCII by construction.
            let name = String(bytes: letters, encoding: .ascii) ?? ""
            guard !digits.isEmpty,
                  let magnitude = (String(bytes: digits, encoding: .ascii).flatMap { Int($0) }) else {
                return ControlWord(name: name, parameter: nil)
            }
            return ControlWord(name: name, parameter: negative ? -magnitude : magnitude)
        }

        // MARK: Lexing helpers

        func hexByte(at offset: Int) -> UInt8? {
            guard offset + 1 < bytes.count,
                  let high = Parser.hexDigit(bytes[offset]),
                  let low = Parser.hexDigit(bytes[offset + 1]) else { return nil }
            return high << 4 | low
        }

        static func isASCIILetter(_ byte: UInt8) -> Bool {
            (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
        }

        static func hexDigit(_ byte: UInt8) -> UInt8? {
            switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
                case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
                default: return nil
            }
        }
    }
}
