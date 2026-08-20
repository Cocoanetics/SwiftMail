// EmailAddress+StringConversion.swift
// Extension to make EmailAddress conform to LosslessStringConvertible

import Foundation

// MARK: - LosslessStringConvertible conformance for EmailAddress

extension EmailAddress: LosslessStringConvertible {
    /**
     Initialize an email address from a string representation
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
                    // Quoted name (with special characters)
                    let name = nsString.substring(with: nameRange1)
                    self.init(name: name, address: email)
                    return
                } else if nameRange2.location != NSNotFound {
                    // Regular name
                    let name = nsString.substring(with: nameRange2).trimmingCharacters(in: .whitespaces)
                    self.init(name: name, address: email)
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
     This uses the formatted representation which includes the name if available
     */
    public var description: String {
        if let name = name, !name.isEmpty {
            // Use quotes if the name contains special characters
            if name.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) {
                return "\"\(name)\" <\(address)>"
            } else {
                return "\(name) <\(address)>"
            }
        } else {
            return address
        }
    }

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

     Use this — not ``description`` — when writing an address into a header.
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
