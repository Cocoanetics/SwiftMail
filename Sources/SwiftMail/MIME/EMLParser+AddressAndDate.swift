// EMLParser+AddressAndDate.swift
// Helpers for parsing comma-separated address lists and RFC 2822 dates.

import Foundation

extension EMLParser {

    // MARK: - Address Parsing

    /// Parse a comma-separated list of email addresses.
    static func parseAddressList(_ value: String?) -> [String] {
        guard let value = value, !value.isEmpty else { return [] }

        // Split by comma, but respect quoted strings and angle brackets
        var addresses: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false

        for char in value {
            switch char {
                case "\"":
                    inQuotes.toggle()
                    current.append(char)
                case "<":
                    inAngle = true
                    current.append(char)
                case ">":
                    inAngle = false
                    current.append(char)
                case "," where !inQuotes && !inAngle:
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        // Keep the structured address in wire form. Decoding the
                        // whole value can turn display-name text into address
                        // syntax before the real addr-spec has been identified.
                        addresses.append(trimmed)
                    }
                    current = ""
                default:
                    current.append(char)
            }
        }

        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            addresses.append(trimmed)
        }

        return addresses
    }

    /// Parse an RFC 5322 address list into structured addresses. Groups
    /// (`Friends: a, b;`) are flattened to their members, as the ENVELOPE path
    /// does; quoted strings and angle brackets are respected and comments dropped.
    static func parseStructuredAddressList(_ value: String?) -> [EmailAddress] {
        guard let value, !value.isEmpty else { return [] }
        var scanner = AddressListScanner()
        value.unicodeScalars.forEach { scanner.consume($0) }
        return scanner.finish()
    }

    // MARK: - Date Parsing

    /// Parse an RFC 2822 date string.
    static func parseRFC2822Date(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",       // Standard RFC 2822
            "EEE, d MMM yyyy HH:mm:ss Z",        // Single-digit day
            "dd MMM yyyy HH:mm:ss Z",            // No day name
            "d MMM yyyy HH:mm:ss Z",             // No day name, single-digit day
            "EEE, dd MMM yyyy HH:mm:ss ZZZZ",    // Named timezone
            "EEE, d MMM yyyy HH:mm:ss ZZZZ",
            "EEE, dd MMM yy HH:mm:ss Z"         // Two-digit year
        ]

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        // Try ISO 8601 as fallback
        let iso = ISO8601DateFormatter()
        return iso.date(from: trimmed)
    }
}

// Header syntax is delimited by ASCII code points, so everything below scans
// Unicode scalars, never `Character`s: a grapheme cluster can join an ASCII
// delimiter (`"`) to a following combining mark (RFC 6532), and would then
// no longer compare equal to it.

private typealias Scalars = [Unicode.Scalar]

private func string(_ scalars: some Sequence<Unicode.Scalar>) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
}

/// Splits an RFC 5322 address list at top-level commas and group delimiters,
/// tracking quoted strings, domain literals (`[IPv6:…]`), angle brackets and
/// comments.
private struct AddressListScanner {
    private var addresses: [EmailAddress] = []
    private var current: Scalars = []
    /// The scalar closing the quoted string or domain literal we are in.
    private var enclosure: Unicode.Scalar?
    private var escaped = false
    private var angleDepth = 0
    private var commentDepth = 0
    private var incomplete = false

    mutating func consume(_ scalar: Unicode.Scalar) {
        // A forbidden control anywhere (quoted or not) makes the list malformed:
        // it is never parsed structurally, so it cannot be silently dropped or
        // mistaken for the parser's own comment marker.
        if EmailAddress.isForbiddenInFieldBody(scalar) {
            incomplete = true
            return
        }
        if escaped {
            if commentDepth == 0 { current.append(scalar) }
            escaped = false
        } else if let closing = enclosure {
            if scalar == "\\" { escaped = true } else if scalar == closing { enclosure = nil }
            current.append(scalar)
        } else if commentDepth > 0 {
            consumeComment(scalar)
        } else {
            consumePlain(scalar)
        }
    }

    /// The addresses, or `[]` if any mailbox in the list could not be parsed:
    /// a structured list is either complete or empty, so callers that prefer
    /// it fall back to the legacy strings rather than silently lose a recipient.
    mutating func finish() -> [EmailAddress] {
        flush()
        return incomplete ? [] : addresses
    }

    private mutating func consumeComment(_ scalar: Unicode.Scalar) {
        switch scalar {
            case "\\": escaped = true
            case "(": commentDepth += 1
            case ")": commentDepth -= 1
            default: break
        }
    }

    private mutating func consumePlain(_ scalar: Unicode.Scalar) {
        switch scalar {
            case "\"": enclosure = "\""; current.append(scalar)
            case "[": enclosure = "]"; current.append(scalar)
            case "(":
                // Inside <…> a comment is dropped; elsewhere its meaning depends
                // on where it sits, so mark it for `parseMailbox`.
                commentDepth = 1
                if angleDepth == 0 { current.append(commentMarker) }
            case "<": angleDepth += 1; current.append(scalar)
            case ">": angleDepth = max(0, angleDepth - 1); current.append(scalar)
            case ":" where angleDepth == 0: current = [] // a group's display name
            case "," where angleDepth == 0, ";" where angleDepth == 0: flush()
            default: current.append(scalar)
        }
    }

    private mutating func flush() {
        defer { current = [] }
        guard current.contains(where: { !isRFCWhitespace($0) && $0 != commentMarker }) else { return }
        if let address = parseMailbox(current), EmailAddress.isHeaderSafe(address.address) {
            addresses.append(address)
        } else {
            incomplete = true
        }
    }
}

/// RFC 5322 whitespace (WSP) is SP and HTAB only. Other Unicode spaces are
/// mailbox or phrase data (RFC 6532), and other controls are rejected, not skipped.
private func isRFCWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    scalar == " " || scalar == "\t"
}

/// Stands in for a comment (CFWS) outside `<…>` until the mailbox is parsed.
/// Input can never contain it: the scanner rejects forbidden controls first.
private let commentMarker: Unicode.Scalar = "\u{1}"

/// One mailbox: `name-addr` (`phrase <addr-spec>`) or a bare `addr-spec`.
private func parseMailbox(_ value: Scalars) -> EmailAddress? {
    let lexemes = lexed(value)
    guard let open = lexemes.first(where: { $0.topLevel && $0.scalar == "<" })?.index else {
        let address = addrSpec(lexemes)
        return address.unicodeScalars.contains("@") ? EmailAddress(address: address) : nil
    }
    guard let close = lexemes.last(where: { $0.topLevel && $0.scalar == ">" && $0.index > open })?.index else {
        return nil
    }
    var inner = lexed(Array(value[(open + 1)..<close]))
    // An obsolete source route (`@relay,@relay:`) ends at the first top-level colon.
    if inner.first(where: { !isRFCWhitespace($0.scalar) && $0.scalar != commentMarker })?.scalar == "@",
       let colon = inner.firstIndex(where: { $0.topLevel && $0.scalar == ":" }) {
        inner.removeSubrange(...colon)
    }
    let address = addrSpec(inner)
    guard address.unicodeScalars.contains("@") else { return nil }
    let name = phraseText(Array(value[..<open]))
    return EmailAddress(name: name.isEmpty ? nil : name, address: address)
}

/// One scalar of a mailbox and whether it is top-level syntax: outside a
/// quoted-string or domain literal (`[…]`), and not quoted-pair escaped.
private struct Lexeme {
    let index: Int
    let scalar: Unicode.Scalar
    let topLevel: Bool
}

private func lexed(_ value: Scalars) -> [Lexeme] {
    var lexemes: [Lexeme] = []
    var closing: Unicode.Scalar?
    var escaped = false
    for (index, scalar) in value.enumerated() {
        var topLevel = false
        if escaped {
            escaped = false
        } else if let end = closing {
            if scalar == "\\" { escaped = true } else if scalar == end { closing = nil }
        } else {
            topLevel = true
            if scalar == "\"" { closing = "\"" } else if scalar == "[" { closing = "]" }
        }
        lexemes.append(Lexeme(index: index, scalar: scalar, topLevel: topLevel))
    }
    return lexemes
}

/// An addr-spec without its CFWS: top-level whitespace and comments are not
/// part of the address; inside a quoted local-part or domain literal they are.
private func addrSpec(_ lexemes: [Lexeme]) -> String {
    string(lexemes.lazy.filter {
        !$0.topLevel || (!isRFCWhitespace($0.scalar) && $0.scalar != commentMarker)
    }.map(\.scalar))
}

/// A display-name phrase as the text it stands for (RFC 5322 §3.2, RFC 2047):
/// quoted-strings unescaped, words separated by CFWS joined by one space and
/// adjacent words kept together, and a word decoded only if the whole word is
/// an encoded-word. Only *whitespace* between two encoded-words is dropped;
/// a comment there still reads as a space.
private func phraseText(_ phrase: Scalars) -> String {
    var text = ""
    var separated = false
    var separatorHasComment = false
    var lastWasEncoded = false
    var index = 0

    func append(_ word: String, encoded: Bool) {
        let joinsEncodedWords = encoded && lastWasEncoded && !separatorHasComment
        if separated && !text.isEmpty && !joinsEncodedWords { text += " " }
        text += encoded ? word.decodeMIMEHeader() : word
        separated = false
        separatorHasComment = false
        lastWasEncoded = encoded
    }

    while index < phrase.count {
        let scalar = phrase[index]
        if isRFCWhitespace(scalar) || scalar == commentMarker {
            separated = true
            if scalar == commentMarker { separatorHasComment = true }
            index += 1
        } else if scalar == "\"" {
            let (word, next) = quotedString(phrase, from: index)
            append(word, encoded: false)
            index = next
        } else {
            var end = index
            while end < phrase.count, !isRFCWhitespace(phrase[end]), phrase[end] != commentMarker,
                  phrase[end] != "\"" {
                end += 1
            }
            let atom = string(phrase[index..<end])
            // An encoded-word is one only when delimited from adjacent words by
            // whitespace or a comment (RFC 2047 §5); next to a word it is literal.
            let delimited = (text.isEmpty || separated) && (end == phrase.count || phrase[end] != "\"")
            append(atom, encoded: delimited && isEncodedWord(atom))
            index = end
        }
    }
    return text
}

/// The unescaped text of the quoted-string starting at `start`, and the index after it.
private func quotedString(_ value: Scalars, from start: Int) -> (String, Int) {
    var text: Scalars = []
    var escaped = false
    var index = start + 1
    while index < value.count {
        let scalar = value[index]
        index += 1
        if escaped {
            text.append(scalar)
            escaped = false
        } else if scalar == "\\" {
            escaped = true
        } else if scalar == "\"" {
            break
        } else {
            text.append(scalar)
        }
    }
    return (string(text), index)
}

/// Whether a whole word is one RFC 2047 encoded-word.
private func isEncodedWord(_ word: String) -> Bool {
    word.range(of: #"^=\?[^?\s]+\?[BbQq]\?[^?\s]*\?=$"#, options: .regularExpression) != nil
}
