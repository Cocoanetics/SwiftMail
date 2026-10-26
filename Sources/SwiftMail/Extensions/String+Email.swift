// String+Email.swift
// Email validation extensions for String

import Foundation

extension String {
    /// Validates if the string is a valid email address format according to RFC 5322
    /// - Returns: True if the string matches email format
    public func isValidEmail() -> Bool {
        // The local part is either a dot-atom-like name or an RFC 5321 Quoted-string
        // ("taro."@docomo.ne.jp). Japanese carriers issued addresses whose local part
        // ends with a dot or has consecutive dots; on the wire they must be quoted.
        let pattern = ##"""
        ^(?:(?:[a-zA-Z0-9](?:[a-zA-Z0-9._%+-]{0,61}[a-zA-Z0-9])?|"(?:[\x20\x21\x23-\x5B\x5D-\x7E]|\\[\x20-\x7E]){1,64}")@
        [a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?
        (?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*
        \.[a-zA-Z]{2,})$
        """##

        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.allowCommentsAndWhitespace])
            let range = NSRange(location: 0, length: self.utf16.count)
            return regex.firstMatch(in: self, options: [], range: range) != nil
        } catch {
            // If regex creation fails (which shouldn't happen with a valid pattern),
            // fall back to a very basic check
            return self.contains("@") &&
                self.split(separator: "@").count == 2 &&
                !self.hasPrefix("@") &&
                !self.hasSuffix("@")
        }
    }
}
