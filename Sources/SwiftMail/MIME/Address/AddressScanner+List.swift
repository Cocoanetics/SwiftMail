// AddressScanner+List.swift
// Address-list elements, and recovery from malformed ones.

import Foundation

/// An address-list element and the text it was written as.
struct ParsedAddressEntry {
    let entry: AddressListEntry

    /// The element's text, unfolded and without surrounding white space.
    let source: String
}

extension AddressScanner {
    /// Reads the next element of an address-list (RFC 5322 §3.4), skipping the
    /// empty elements that obs-addr-list allows. Returns `nil` at the end of
    /// the text.
    ///
    /// An element that doesn't match the grammar, or that isn't followed by a
    /// comma or the end of the text, becomes invalid text reaching up to the
    /// next comma its syntax doesn't swallow (see ``elementEnd(from:)``). The
    /// elements around it are read normally.
    mutating func readListElement() -> ParsedAddressEntry? {
        while true {
            let start = position
            guard (try? skipCFWS()) != nil else {
                return invalidElement(from: start)
            }
            if isAtEnd {
                return nil
            }
            if !consume(",") {
                position = start
                return readAddressElement()
            }
        }
    }

    private mutating func readAddressElement() -> ParsedAddressEntry {
        let start = position
        if let entry = try? readAddress(), isAtEnd || current == "," {
            let source = sourceText(start..<position)
            _ = consume(",")
            return ParsedAddressEntry(entry: entry, source: source)
        }
        return invalidElement(from: start)
    }

    private mutating func invalidElement(from start: Int) -> ParsedAddressEntry {
        let end = elementEnd(from: start)
        let source = sourceText(start..<end)
        position = end
        _ = consume(",")
        return ParsedAddressEntry(entry: .invalid(source), source: source)
    }

    /// Where the element starting at `start` ends: at the next comma outside a
    /// quoted-string, comment, domain literal, angle brackets or group. An
    /// unterminated construct runs to the end of the text, so a comma inside it
    /// is never mistaken for the start of another address.
    func elementEnd(from start: Int) -> Int {
        var boundary = ElementBoundary()
        var index = start
        while index < scalars.count, !boundary.endsElement(scalars[index]) {
            index += 1
        }
        return index
    }

    /// The text in `range`, with the line breaks of folds removed and without
    /// surrounding white space.
    func sourceText(_ range: Range<Int>) -> String {
        var text: [Unicode.Scalar] = []
        for index in range where !isFoldingLineBreak(at: index) {
            text.append(scalars[index])
        }
        let trimmed = text.drop(while: AddressSyntax.isWSP).reversed().drop(while: AddressSyntax.isWSP).reversed()
        return String(unicodeScalars: trimmed)
    }

    /// Whether the scalar at `index` is the CR or LF of a line break that folds,
    /// i.e. white space follows the line break.
    private func isFoldingLineBreak(at index: Int) -> Bool {
        let lineFeed = scalars[index] == "\r" ? index + 1 : index
        guard scalar(at: lineFeed) == "\n", let next = scalar(at: lineFeed + 1) else { return false }
        return AddressSyntax.isWSP(next)
    }
}

/// Follows the lexical context of malformed address text, to find the comma
/// that ends its element.
private struct ElementBoundary {
    /// The scalar that closes the quoted-string or domain literal being read.
    private var closing: Unicode.Scalar?
    private var isEscaped = false
    private var commentDepth = 0
    private var angleDepth = 0
    private var isInGroup = false

    /// Reads one scalar and returns whether it is the comma that ends the element.
    mutating func endsElement(_ scalar: Unicode.Scalar) -> Bool {
        if isEscaped {
            isEscaped = false
        } else if closing != nil || commentDepth > 0 {
            readEnclosed(scalar)
        } else {
            return readTopLevel(scalar)
        }
        return false
    }

    /// A scalar inside a quoted-string, domain literal or comment.
    private mutating func readEnclosed(_ scalar: Unicode.Scalar) {
        if scalar == "\\" {
            isEscaped = true
        } else if let closing {
            self.closing = scalar == closing ? nil : closing
        } else if scalar == "(" {
            commentDepth += 1
        } else if scalar == ")" {
            commentDepth -= 1
        }
    }

    private mutating func readTopLevel(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
            case "\"":
                closing = "\""
            case "[":
                closing = "]"
            case "(":
                commentDepth = 1
            case "<":
                angleDepth += 1
            case ">":
                angleDepth = max(0, angleDepth - 1)
            default:
                return readDelimiter(scalar)
        }
        return false
    }

    /// `:` opens a group and `;` closes it; a comma ends the element when it is
    /// outside angle brackets and groups.
    private mutating func readDelimiter(_ scalar: Unicode.Scalar) -> Bool {
        guard angleDepth == 0 else { return false }
        switch scalar {
            case ":":
                isInGroup = true
            case ";":
                isInGroup = false
            case ",":
                return !isInGroup
            default:
                break
        }
        return false
    }
}
