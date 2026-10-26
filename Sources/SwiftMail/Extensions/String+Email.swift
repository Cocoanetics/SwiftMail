// String+Email.swift
// Email validation extensions for String

import Foundation

extension String {
    /// Validates if the string is a valid email address format according to RFC 5322
    /// - Returns: True if the string matches email format
    public func isValidEmail() -> Bool {
        let label = ##"[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?"##
        let domainPattern = ##"\A"## + label + ##"(?:\."## + label + ##")*\.[a-zA-Z]{2,}\z"##
        // The local part is either a dot-atom-like name or an RFC 5321 Quoted-string
        // ("taro."@docomo.ne.jp). Japanese carriers issued addresses whose local part
        // ends with a dot or has consecutive dots; on the wire they must be quoted.
        let pattern = ##"""
        \A(?:(?:[a-zA-Z0-9](?:[a-zA-Z0-9._%+-]{0,61}[a-zA-Z0-9])?
        |"(?:[\x20\x21\x23-\x5B\x5D-\x7E]|\\[\x20-\x7E]){1,64}")@
        [a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?
        (?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*
        \.[a-zA-Z]{2,})\z
        """##

        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.allowCommentsAndWhitespace])
            let range = NSRange(location: 0, length: self.utf16.count)
            if regex.firstMatch(in: self, options: [], range: range) != nil { return withinLengthLimits }
            return isCanonicalASCIIAddrSpec(domainPattern: domainPattern)
        } catch {
            // If regex creation fails (which shouldn't happen with a valid pattern),
            // fall back to a very basic check
            return self.contains("@") &&
                self.split(separator: "@").count == 2 &&
                !self.hasPrefix("@") &&
                !self.hasSuffix("@")
        }
    }

    /// An addr-spec that ``AddressParser`` reads back as exactly this text:
    /// local parts with RFC 5322 `atext` such as `o'neil` or `!user` that the
    /// pattern above doesn't list. Only printable ASCII (no SMTPUTF8), and the
    /// domain must still match the pattern, so the formatter writes the same
    /// address into the header that the envelope carries.
    private func isCanonicalASCIIAddrSpec(domainPattern: String) -> Bool {
        guard unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) || $0 == " " }),
              AddressParser.parseAddressList(self) == [.mailbox(EmailAddress(address: self))],
              withinLengthLimits,
              let atSign = range(of: "@", options: .backwards),
              self[..<atSign.lowerBound] != "\"\"" else { return false }  // empty quoted local part: no mailbox
        let domain = String(self[atSign.upperBound...])
        return domain.range(of: domainPattern, options: .regularExpression) != nil
    }

    /// RFC 5321 4.5.3.1: a local part of at most 64 octets — counted as written,
    /// so the quotes and both octets of each quoted-pair count — and a path of
    /// at most 254 octets.
    private var withinLengthLimits: Bool {
        guard let atSign = range(of: "@", options: .backwards) else { return false }
        return self[..<atSign.lowerBound].utf8.count <= 64 && utf8.count <= 254
    }
}
