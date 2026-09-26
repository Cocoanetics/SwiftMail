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
        value.forEach { scanner.consume($0) }
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

/// Splits an RFC 5322 address list at top-level commas and group delimiters,
/// tracking quoted strings, domain literals (`[IPv6:…]`), angle brackets and
/// (dropped) comments.
private struct AddressListScanner {
    private var addresses: [EmailAddress] = []
    private var current = ""
    /// The character closing the quoted string or domain literal we are in.
    private var enclosure: Character?
    private var escaped = false
    private var angleDepth = 0
    private var commentDepth = 0
    private var incomplete = false

    mutating func consume(_ char: Character) {
        if escaped {
            if commentDepth == 0 { current.append(char) }
            escaped = false
        } else if let closing = enclosure {
            if char == "\\" { escaped = true } else if char == closing { enclosure = nil }
            current.append(char)
        } else if commentDepth > 0 {
            consumeComment(char)
        } else {
            consumePlain(char)
        }
    }

    /// The addresses, or `[]` if any mailbox in the list could not be parsed:
    /// a structured list is either complete or empty, so callers that prefer
    /// it fall back to the legacy strings rather than silently lose a recipient.
    mutating func finish() -> [EmailAddress] {
        flush()
        return incomplete ? [] : addresses
    }

    private mutating func consumeComment(_ char: Character) {
        switch char {
            case "\\": escaped = true
            case "(": commentDepth += 1
            case ")": commentDepth -= 1
            default: break
        }
    }

    private mutating func consumePlain(_ char: Character) {
        switch char {
            case "\"": enclosure = "\""; current.append(char)
            case "[": enclosure = "]"; current.append(char)
            case "(":
                // Inside <…> a comment is dropped; elsewhere its meaning depends
                // on where it sits, so mark it for `parseMailbox`.
                commentDepth = 1
                if angleDepth == 0 { current.append(commentMarker) }
            case "<": angleDepth += 1; current.append(char)
            case ">": angleDepth = max(0, angleDepth - 1); current.append(char)
            case ":" where angleDepth == 0: current = "" // a group's display name
            case "," where angleDepth == 0, ";" where angleDepth == 0: flush()
            default: current.append(char)
        }
    }

    private mutating func flush() {
        defer { current = "" }
        guard current.contains(where: { !$0.isWhitespace && $0 != commentMarker }) else { return }
        if let address = parseMailbox(current), EmailAddress.isHeaderSafe(address.address) {
            addresses.append(address)
        } else {
            incomplete = true
        }
    }
}

/// Stands in for a comment (CFWS) outside `<…>` until the mailbox is parsed.
private let commentMarker: Character = "\u{1}"

/// One mailbox: `name-addr` (`phrase <addr-spec>`) or a bare `addr-spec`.
private func parseMailbox(_ value: String) -> EmailAddress? {
    let tokens = lexed(value[...])
    guard let open = tokens.first(where: { $0.topLevel && $0.char == "<" })?.index else {
        let address = addrSpec(tokens)
        return address.contains("@") ? EmailAddress(address: address) : nil
    }
    guard let close = tokens.last(where: { $0.topLevel && $0.char == ">" && $0.index > open })?.index else {
        return nil
    }
    var inner = lexed(value[value.index(after: open)..<close])
    // An obsolete source route (`@relay,@relay:`) ends at the first top-level colon.
    if inner.first(where: { !$0.char.isWhitespace && $0.char != commentMarker })?.char == "@",
       let colon = inner.firstIndex(where: { $0.topLevel && $0.char == ":" }) {
        inner.removeSubrange(...colon)
    }
    let address = addrSpec(inner)
    guard address.contains("@") else { return nil }
    let name = phraseText(value[..<open])
    return EmailAddress(name: name.isEmpty ? nil : name, address: address)
}

/// One character of a mailbox and whether it is top-level syntax: outside a
/// quoted-string or domain literal (`[…]`), and not quoted-pair escaped.
private struct Lexeme {
    let index: String.Index
    let char: Character
    let topLevel: Bool
}

private func lexed(_ value: Substring) -> [Lexeme] {
    var lexemes: [Lexeme] = []
    var closing: Character?
    var escaped = false
    for index in value.indices {
        let char = value[index]
        var topLevel = false
        if escaped {
            escaped = false
        } else if let end = closing {
            if char == "\\" { escaped = true } else if char == end { closing = nil }
        } else {
            topLevel = true
            if char == "\"" { closing = "\"" } else if char == "[" { closing = "]" }
        }
        lexemes.append(Lexeme(index: index, char: char, topLevel: topLevel))
    }
    return lexemes
}

/// An addr-spec without its CFWS: top-level whitespace and comments are not
/// part of the address; inside a quoted local-part or domain literal they are.
private func addrSpec(_ lexemes: [Lexeme]) -> String {
    var result = ""
    for lexeme in lexemes where !lexeme.topLevel || (!lexeme.char.isWhitespace && lexeme.char != commentMarker) {
        result.append(lexeme.char)
    }
    return result
}

/// A display-name phrase as the text it stands for (RFC 5322 §3.2, RFC 2047):
/// quoted-strings unescaped, words separated by CFWS joined by one space and
/// adjacent words kept together, and a word decoded only if the whole word is
/// an encoded-word, with the space between two encoded-words dropped.
private func phraseText(_ phrase: Substring) -> String {
    var text = ""
    var separated = false
    var lastWasEncoded = false
    var index = phrase.startIndex

    func append(_ word: String, encoded: Bool) {
        if separated && !text.isEmpty && !(encoded && lastWasEncoded) { text += " " }
        text += encoded ? word.decodeMIMEHeader() : word
        separated = false
        lastWasEncoded = encoded
    }

    while index < phrase.endIndex {
        let char = phrase[index]
        if char.isWhitespace || char == commentMarker {
            separated = true
            index = phrase.index(after: index)
        } else if char == "\"" {
            let (word, next) = quotedString(phrase, from: index)
            append(word, encoded: false)
            index = next
        } else {
            var end = index
            while end < phrase.endIndex, !phrase[end].isWhitespace, phrase[end] != commentMarker,
                  phrase[end] != "\"" {
                end = phrase.index(after: end)
            }
            let atom = String(phrase[index..<end])
            append(atom, encoded: isEncodedWord(atom))
            index = end
        }
    }
    return text
}

/// The unescaped text of the quoted-string starting at `start`, and the index after it.
private func quotedString(_ value: Substring, from start: Substring.Index) -> (String, Substring.Index) {
    var text = ""
    var escaped = false
    var index = value.index(after: start)
    while index < value.endIndex {
        let char = value[index]
        index = value.index(after: index)
        if escaped {
            text.append(char)
            escaped = false
        } else if char == "\\" {
            escaped = true
        } else if char == "\"" {
            break
        } else {
            text.append(char)
        }
    }
    return (text, index)
}

/// Whether a whole word is one RFC 2047 encoded-word.
private func isEncodedWord(_ word: String) -> Bool {
    word.range(of: #"^=\?[^?\s]+\?[BbQq]\?[^?\s]*\?=$"#, options: .regularExpression) != nil
}
