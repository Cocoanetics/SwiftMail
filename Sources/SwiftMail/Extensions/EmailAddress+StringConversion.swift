// EmailAddress+StringConversion.swift
// Extension to make EmailAddress conform to LosslessStringConvertible

import Foundation

// MARK: - LosslessStringConvertible conformance for EmailAddress

extension EmailAddress: LosslessStringConvertible {
    /**
     Initialize an email address from a string representation

     A *bare* encoded-word display name is RFC 2047-decoded — that is how a
     non-ASCII name written by ``description``, or read off the wire, arrives —
     so the round trip yields the name the recipient actually sees, the same
     treatment the IMAP `ENVELOPE` path gives a `personName`. A display name
     inside a *quoted-string* is taken literally: RFC 2047 §5 forbids reading an
     encoded-word there, so text that merely looks like `=?…?=` is returned
     verbatim, not decoded.

     - Parameter description: The string representation of the email address
     */
    public init?(_ description: String) {
        let trimmed = description.trimmingCharacters(in: .whitespaces)

        // Simple email address without a name
        if trimmed.contains("@") && !trimmed.contains("<") && !trimmed.contains(">") {
            self.init(address: trimmed)
            return
        }

        // Email address with a name
        // Format: "Name <email@example.com>" or "\"Name with, special chars\" <email@example.com>"
        guard trimmed.last == ">",
              let addressStart = trimmed.dropLast().lastIndex(of: "<") else {
            return nil
        }

        let address = trimmed[trimmed.index(after: addressStart)..<trimmed.index(before: trimmed.endIndex)]
        guard !address.isEmpty, !address.contains("<"), !address.contains(">") else {
            return nil
        }

        let phrase = trimmed[..<addressStart].trimmingCharacters(in: .whitespaces)
        guard !phrase.isEmpty else {
            self.init(address: String(address))
            return
        }

        if phrase.first == "\"" {
            // A quoted-string always carries a literal display name: RFC 2047
            // §5 forbids reading an encoded-word inside one.
            guard phrase.last == "\"", phrase.count >= 2 else { return nil }
            self.init(name: String(phrase.dropFirst().dropLast()), address: String(address))
        } else {
            // Decode only complete encoded-word tokens. Decoding the `=?…?=`
            // substring of an ordinary atom would corrupt the phrase and can
            // even manufacture control characters that were not on the wire.
            self.init(name: phrase.decodingRFC2047Phrase(), address: String(address))
        }
    }

    /**
     Get the string representation of the email address

     This is the RFC 5322 address string, including the display name if there is
     one — the same text ``headerString()`` writes into a header field, and the
     text ``init(_:)`` reads back. It has always produced address syntax rather
     than free text (a name with a comma comes back quoted), so a name that
     syntax cannot carry literally is RFC 2047-encoded here too; see
     ``headerString()`` for which names those are and why. Emitting a name raw
     when it holds a CR or LF is what let a `Message` built from an `Email` grow
     a header field its author never wrote.
     */
    public var description: String { headerString() }

    /**
     RFC 5322 address string for use in a header field (`From`/`To`/`Cc`/…).

     A display name that cannot be written literally is RFC 2047-encoded. That
     covers two cases:

     - The name is not a valid field body — it holds non-ASCII text or a control
       character. A CR or LF here *ends the header field*, so an unencoded name
       turns the rest of the value into new header lines.
     - The name holds a `"` or a `\`, the two characters that would escape the
       quoted-string it would otherwise be wrapped in. An embedded `"` closes the
       string early and lets the remainder be read as further address syntax; a
       `\` is read as a quoted-pair, so the literal text is lost.

     An encoded-word may replace a word inside a phrase (RFC 2047 §5) and its
     output is bare printable ASCII, so encoding both carries the name intact and
     removes the escape. Encoded-words must not appear inside a quoted-string, so
     an encoded name is emitted bare (never quoted).

     ``description`` returns this, so every caller that formats an address gets a
     value a header field can hold. ``init(_:)`` decodes the name again, so the
     round trip still yields the original text.
     */
    func headerString() -> String {
        guard let name = name, !name.isEmpty else { return address }
        if name.rfc2047RequiresEncodingAsDisplayName {
            return "\(name.rfc2047EncodedWords()) <\(address)>"
        }
        // Use quotes if the (plain ASCII) name contains special characters
        if name.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) {
            return "\"\(name)\" <\(address)>"
        }
        return "\(name) <\(address)>"
    }
}

private extension StringProtocol {
    /// Decode encoded-words only when each occupies a complete phrase token.
    /// RFC 2047 whitespace between adjacent encoded-words is not displayed.
    func decodingRFC2047Phrase() -> String {
        var result = ""
        var pendingWhitespace = ""
        var token = ""
        var previousWasEncoded = false

        func appendToken() {
            guard !token.isEmpty else { return }
            let decoded = token.decodeMIMEHeader()
            let isEncoded = decoded != token && token.isCompleteRFC2047EncodedWord

            if !(previousWasEncoded && isEncoded) {
                result += pendingWhitespace
            }
            result += isEncoded ? decoded : token
            pendingWhitespace = ""
            previousWasEncoded = isEncoded
            token = ""
        }

        for character in self {
            let isWhitespace = character.unicodeScalars.allSatisfy { scalar in
                scalar == " " || scalar == "\t" || scalar == "\r" || scalar == "\n"
            }
            if isWhitespace {
                appendToken()
                pendingWhitespace.append(character)
            } else {
                token.append(character)
            }
        }
        appendToken()
        result += pendingWhitespace
        return result
    }
}

private extension String {
    var isCompleteRFC2047EncodedWord: Bool {
        let pattern = #"^=\?[^?]+\?[bBqQ]\?[^?]*\?=$"#
        return range(of: pattern, options: .regularExpression) == startIndex..<endIndex
    }
}
