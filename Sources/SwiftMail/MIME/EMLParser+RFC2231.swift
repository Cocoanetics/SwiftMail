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
    /// is legal — but leaving it blank "MUST NOT be done in order to
    /// indicate a default character set", so only US-ASCII bytes have a
    /// meaning there; anything else yields `nil`. Any charset the platform can name is honored, so a filename
    /// labelled `windows-1252` or `iso-8859-15` decodes as such rather than
    /// being discarded; a charset the platform does not know, or bytes that
    /// are not valid in the charset named, yield `nil`. A `nil` result lets
    /// the literal spelling of the parameter, if the sender wrote one, win.
    private static func decodeExtendedBytes(_ bytes: [UInt8], charset: String) -> String? {
        if charset.isEmpty {
            guard bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
            return String(bytes: bytes, encoding: .ascii)
        }
        guard let encoding = String.Encoding(ianaCharsetName: charset),
              encoding != .utf8 || isGenuineUTF8Label(charset) else { return nil }
        return String(bytes: bytes, encoding: encoding)
    }

    /// Whether a `.utf8` resolution of `charset` names UTF-8 rather than
    /// standing in for a charset the platform cannot decode.
    ///
    /// On Apple platforms CoreFoundation's IANA table is authoritative, so
    /// every `.utf8` it returns is trusted, aliases such as
    /// `unicode-1-1-utf-8` included. Without CoreFoundation, SwiftCross's
    /// hand table resolves legacy charsets it has no converter for (GBK,
    /// Big5, EUC-KR, KOI8-R, macintosh, …) to `.utf8` as a best-effort
    /// placeholder, and a wrong decode is worse than none because `nil` lets
    /// the sender's literal spelling win. There the label itself decides:
    /// stripped of everything but letters and digits, every UTF-8 spelling
    /// the resolver accepts (`utf-8`, `utf8`, `utf8mb4`, `utf_8`,
    /// `utf-8$esc`) starts with `utf8` and no placeholder label does. On
    /// those platforms a placeholder added to the table later is still
    /// rejected, and a UTF-8 alias spelled some other way fails safe to the
    /// literal parameter.
    private static func isGenuineUTF8Label(_ charset: String) -> Bool {
        #if canImport(CoreFoundation) && (os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
        return true
        #else
        let alphanumerics = charset.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return alphanumerics.hasPrefix("utf8")
        #endif
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
