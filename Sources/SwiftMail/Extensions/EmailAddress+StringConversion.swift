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
        // Simple email address without a name
        if description.contains("@") && !description.contains("<") {
            self.init(address: description)
            return
        }

        // Email address with a name
        // Format: "Name <email@example.com>" or "\"Name with, special chars\" <email@example.com>"
        let namePattern = "(?:\"([^\"]+)\"|([^<]*))\\s*<([^>]+)>"
        let nameRegex = try? NSRegularExpression(pattern: namePattern, options: [])

        let descriptionRange = NSRange(location: 0, length: description.count)
        if let match = nameRegex?.firstMatch(in: description, options: [], range: descriptionRange) {
            let nameRange1 = match.range(at: 1)
            let nameRange2 = match.range(at: 2)
            let emailRange = match.range(at: 3)

            if emailRange.location != NSNotFound {
                let nsString = description as NSString
                let email = nsString.substring(with: emailRange)

                // Check if we have a quoted name or a regular name
                if nameRange1.location != NSNotFound {
                    // Quoted name (with special characters). A quoted-string
                    // always carries a LITERAL display name: RFC 2047 §5 forbids
                    // reading an encoded-word inside a quoted-string, so a name
                    // that merely *looks* like `=?UTF-8?B?…?=` is exactly that
                    // text and must be handed back verbatim, never MIME-decoded.
                    // A non-ASCII name never reaches this branch — `headerString`
                    // emits it as a *bare* encoded-word, which the unquoted
                    // branch below decodes.
                    let name = nsString.substring(with: nameRange1)
                    self.init(name: name, address: email)
                    return
                } else if nameRange2.location != NSNotFound {
                    // Regular name
                    let name = nsString.substring(with: nameRange2).trimmingCharacters(in: .whitespaces)
                    self.init(name: name.decodeMIMEHeader(), address: email)
                    return
                } else {
                    // Just the email
                    self.init(address: email)
                    return
                }
            }
        }

        return nil
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
