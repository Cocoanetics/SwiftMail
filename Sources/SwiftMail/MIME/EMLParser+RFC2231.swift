// EMLParser+RFC2231.swift
// RFC 2231 extended parameter values: `name*=charset'language'value` and
// numbered continuation sections.

import Foundation

extension EMLParser {

    // MARK: - RFC 2231 Extended Parameters

    /// Extract an RFC 2231 extended parameter (`name*=charset'language'value`)
    /// and percent-decode its value. Continuations may mix encoded segments
    /// (`name*0*=`, `name*1*=`) with literal ones (`name*2=`). Encoded segments
    /// are percent-decoded individually while literal segments retain `%`
    /// sequences as text, per RFC 2231 §4.1.
    static func extractExtendedHeaderParam(from header: String, named name: String) -> String? {
        let raw: String
        let continuations: [(value: String, encoded: Bool)]
        if let single = extractHeaderParam(from: header, named: name + "*") {
            raw = single
            continuations = []
        } else if let continued = extendedContinuation(from: header, named: name) {
            raw = continued.initial
            continuations = continued.following
        } else {
            return nil
        }

        guard let charsetEnd = raw.firstIndex(of: "'") else { return nil }
        let languageStart = raw.index(after: charsetEnd)
        guard let languageEnd = raw[languageStart...].firstIndex(of: "'") else { return nil }

        let charset = raw[..<charsetEnd].lowercased()
        let encodedValue = raw[raw.index(after: languageEnd)...]
        guard var bytes = percentDecodedBytes(encodedValue) else { return nil }
        guard let continuationBytes = decodedContinuationBytes(continuations) else { return nil }
        bytes.append(contentsOf: continuationBytes)
        return decodeExtendedBytes(bytes, charset: charset)
    }

    /// Decode the bytes of an extended parameter value in the charset its
    /// `charset'language'` prefix names.
    ///
    /// RFC 2231 §4 makes the charset field optional — `filename*=''a.pdf`
    /// is legal, and the value is the bytes as written. Any charset the
    /// platform can name is honored, so a filename labelled `windows-1252`
    /// or `iso-8859-15` decodes as such rather than being discarded; a
    /// charset the platform does not know, or bytes that are not valid in
    /// the charset named, yield `nil` and the literal spelling of the
    /// parameter, if the sender wrote one, is used instead.
    private static func decodeExtendedBytes(_ bytes: [UInt8], charset: String) -> String? {
        if charset.isEmpty {
            // No charset was named, so the bytes carry no declared meaning
            // beyond US-ASCII. UTF-8 reads every US-ASCII value unchanged and
            // still rejects a byte sequence that is not text.
            return String(bytes: bytes, encoding: .utf8)
        }
        guard let encoding = String.Encoding(ianaCharsetName: charset),
              encoding != .utf8 || isUTF8Label(charset) else { return nil }
        return String(bytes: bytes, encoding: encoding)
    }

    /// Whether a charset label names UTF-8 itself (or its US-ASCII subset).
    ///
    /// On platforms without CoreFoundation, `String.Encoding(ianaCharsetName:)`
    /// resolves legacy charsets it has no converter for (GBK, Big5, EUC-KR,
    /// KOI8-R, …) to `.utf8` as a best-effort placeholder. Here a wrong
    /// decode is worse than none, because `nil` lets the sender's literal
    /// spelling win, so a UTF-8 result is trusted only for a UTF-8 label.
    private static func isUTF8Label(_ charset: String) -> Bool {
        let label = charset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["utf-8", "utf8", "utf8mb4", "us-ascii", "ascii", "iso646-us"].contains(label)
    }

    /// Collect the RFC 2231 §3 continuation sections of an extended
    /// parameter from ONE pass over the header's parameters.
    ///
    /// Section numbers start at 0, count in decimal without leading zeroes,
    /// and have no gaps; the value ends at the first missing section. Where
    /// a sender repeats a section, the first occurrence stands, matching
    /// ``extractHeaderParam(from:named:)``. The initial section has to be the
    /// encoded spelling (`name*0*=`), which is where the charset prefix is.
    private static func extendedContinuation(
        from header: String,
        named name: String
    ) -> (initial: String, following: [(value: String, encoded: Bool)])? {
        let prefix = name.lowercased() + "*"
        var sections: [Int: (value: String, encoded: Bool)] = [:]

        for parameter in parameters(of: header) where parameter.attribute.hasPrefix(prefix) {
            var digits = parameter.attribute.dropFirst(prefix.count)
            let encoded = digits.last == "*"
            if encoded {
                digits.removeLast()
            }
            guard !digits.isEmpty,
                  digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  digits == "0" || digits.first != "0",
                  let section = Int(digits),
                  sections[section] == nil
            else { continue }
            sections[section] = (parameter.value, encoded)
        }

        guard let initial = sections[0], initial.encoded else { return nil }
        var following: [(value: String, encoded: Bool)] = []
        var index = 1
        while let next = sections[index] {
            following.append(next)
            index += 1
        }
        return (initial.value, following)
    }

    private static func decodedContinuationBytes(_ continuations: [(value: String, encoded: Bool)]) -> [UInt8]? {
        var bytes: [UInt8] = []
        for continuation in continuations {
            if continuation.encoded {
                guard let decoded = percentDecodedBytes(continuation.value[...]) else { return nil }
                bytes.append(contentsOf: decoded)
            } else {
                bytes.append(contentsOf: continuation.value.utf8)
            }
        }
        return bytes
    }

    static func isFilenameContinuation(_ attribute: String) -> Bool {
        for name in ["name", "filename"] where attribute.hasPrefix(name + "*") {
            var suffix = attribute.dropFirst(name.count + 1)
            if suffix.last == "*" {
                suffix.removeLast()
            }
            if !suffix.isEmpty && suffix.allSatisfy(\.isNumber) {
                return true
            }
        }
        return false
    }

    private static func percentDecodedBytes(_ value: Substring) -> [UInt8]? {
        let bytes = Array(value.utf8)
        var result: [UInt8] = []
        var index = 0

        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%") {
                guard index + 2 < bytes.count,
                      let high = hexValue(bytes[index + 1]),
                      let low = hexValue(bytes[index + 2])
                else { return nil }
                result.append(high << 4 | low)
                index += 3
            } else {
                result.append(bytes[index])
                index += 1
            }
        }
        return result
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                return byte - UInt8(ascii: "0")
            case UInt8(ascii: "A")...UInt8(ascii: "F"):
                return byte - UInt8(ascii: "A") + 10
            case UInt8(ascii: "a")...UInt8(ascii: "f"):
                return byte - UInt8(ascii: "a") + 10
            default:
                return nil
        }
    }

}
