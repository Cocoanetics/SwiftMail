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
                // CFWS: outside an addr-spec a comment is whitespace.
                commentDepth = 1
                if angleDepth == 0 { appendSpace() }
            case "<": angleDepth += 1; current.append(char)
            case ">": angleDepth = max(0, angleDepth - 1); current.append(char)
            case ":" where angleDepth == 0: current = "" // a group's display name
            case "," where angleDepth == 0, ";" where angleDepth == 0: flush()
            case _ where char.isWhitespace && angleDepth == 0: appendSpace()
            default: current.append(char)
        }
    }

    /// One space for any run of whitespace and comments between words.
    private mutating func appendSpace() {
        if let last = current.last, !last.isWhitespace { current.append(" ") }
    }

    private mutating func flush() {
        defer { current = "" }
        guard !current.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let address = EmailAddress(current) ?? mixedPhraseAddress(current),
           EmailAddress.isHeaderSafe(address.address) {
            addresses.append(address)
        } else {
            incomplete = true
        }
    }
}

/// `name-addr` whose phrase mixes quoted-strings and atoms (`"John" Doe <…>`),
/// which ``EmailAddress/init(_:)`` does not accept. Quoted words are taken
/// literally; bare words may be RFC 2047 encoded-words.
private func mixedPhraseAddress(_ value: String) -> EmailAddress? {
    guard let open = value.lastIndex(of: "<"), let close = value.lastIndex(of: ">"), open < close else {
        return nil
    }
    let address = value[value.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
    guard !address.isEmpty else { return nil }

    var words: [String] = []
    var word = ""
    var inQuotes = false
    var escaped = false
    func endWord(quoted: Bool) {
        if !word.isEmpty { words.append(quoted ? word : word.decodeMIMEHeader()) }
        word = ""
    }
    for char in value[..<open] {
        if escaped {
            word.append(char)
            escaped = false
        } else if inQuotes {
            if char == "\\" { escaped = true } else if char == "\"" { endWord(quoted: true); inQuotes = false } else {
                word.append(char)
            }
        } else if char == "\"" {
            endWord(quoted: false)
            inQuotes = true
        } else if char.isWhitespace {
            endWord(quoted: false)
        } else {
            word.append(char)
        }
    }
    endWord(quoted: inQuotes)
    let name = words.joined(separator: " ")
    return EmailAddress(name: name.isEmpty ? nil : name, address: address)
}
