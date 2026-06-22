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

     Identical to ``description`` for ASCII display names, but a non-ASCII name
     is RFC 2047-encoded. Encoded-words must not appear inside a quoted-string,
     so an encoded name is emitted bare (never quoted). Use this — not
     ``description`` — when writing an address into a header so that non-ASCII
     names survive transport instead of being mojibake'd.
     */
    func headerString() -> String {
        guard let name = name, !name.isEmpty else { return address }
        if name.contains(where: { !$0.isASCII }) {
            return "\(name.rfc2047EncodedHeader()) <\(address)>"
        }
        // Use quotes if the (ASCII) name contains special characters
        if name.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) {
            return "\"\(name)\" <\(address)>"
        }
        return "\(name) <\(address)>"
    }
}
