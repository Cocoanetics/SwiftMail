import Foundation

extension String {
    /// The longest line, in octets and without its CRLF, that RFC 5322 §2.1.1
    /// allows (RFC 6532 §3.4 keeps the limit in octets for UTF-8 content).
    static let maximumLineOctets = 998

    /// Determines if a string is safe for 8bit MIME transmission according to SMTP standards.
    /// Verifies:
    /// - No NULL bytes (which would terminate message in some implementations)
    /// - No control characters except CR, LF, and TAB
    /// - No line longer than 998 octets of UTF-8 (RFC 5322 §2.1.1, RFC 6532 §3.4).
    ///   Lines end at CR or LF, the only characters that become line breaks once
    ///   the text is written with CRLF line endings (``crlfNormalized``); a
    ///   multibyte character counts as all of its octets.
    public func isSafe8BitContent() -> Bool {
        // Quick return if empty string
        if isEmpty { return true }

        // Define allowed control characters (CR, LF, TAB)
        let allowedControlChars: Set<UInt8> = [0x09, 0x0A, 0x0D] // TAB, LF, CR

        // Check each character for NULL bytes and problematic control characters
        for char in utf8 where char < 32 || char == 127 {
            if char == 0 { // NULL byte - immediate fail
                return false
            }

            if !allowedControlChars.contains(char) { // Other control character not in our allowed set
                return false
            }
        }

        var lineOctets = 0
        for byte in utf8 {
            if byte == 0x0A || byte == 0x0D {
                lineOctets = 0
                continue
            }
            lineOctets += 1
            if lineOctets > Self.maximumLineOctets { return false }
        }
        return true
    }

    /// The string with every line ending (CRLF, a bare LF or a bare CR) written
    /// as CRLF, the only line ending SMTP DATA and MIME bodies allow
    /// (RFC 5321 §2.3.8, RFC 5322 §2.3).
    var crlfNormalized: String {
        replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }
}
