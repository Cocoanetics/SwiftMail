// EMLParser+RFC2047.swift
// RFC 2047 encoded word decoding plus the small String.Encoding charset map.

import Foundation

extension EMLParser {

    // MARK: - RFC 2047 Encoded Word Decoding

    /// Decode RFC 2047 encoded words (=?charset?encoding?text?=).
    static func decodeRFC2047(_ input: String) -> String? {
        let pattern = "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?="

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }

        let nsInput = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))

        if matches.isEmpty {
            return input
        }

        var result = input
        // Process matches in reverse to preserve indices
        for match in matches.reversed() {
            guard match.numberOfRanges >= 4 else { continue }

            let fullMatch = nsInput.substring(with: match.range)
            let charset = nsInput.substring(with: match.range(at: 1))
            let encodingChar = nsInput.substring(with: match.range(at: 2)).uppercased()
            let encodedText = nsInput.substring(with: match.range(at: 3))

            let encoding = String.Encoding.fromCharsetName(charset) ?? .utf8

            if let decoded = decodeEncodedWord(text: encodedText, encodingChar: encodingChar, encoding: encoding) {
                result = result.replacingOccurrences(of: fullMatch, with: decoded)
            }
        }

        return result
    }

    /// Decode a single encoded word body using Base64 or Quoted-Printable.
    private static func decodeEncodedWord(text: String, encodingChar: String, encoding: String.Encoding) -> String? {
        switch encodingChar {
            case "B":
                // Base64
                if let data = Data(base64Encoded: text) {
                    return String(data: data, encoding: encoding)
                }
                return nil
            case "Q":
                // Quoted-printable (underscore = space)
                let qpString = text.replacingOccurrences(of: "_", with: " ")
                return decodeQP(qpString, encoding: encoding)
            default:
                return nil
        }
    }

    /// Decode a quoted-printable string with a specific encoding.
    static func decodeQP(_ input: String, encoding: String.Encoding) -> String? {
        var bytes: [UInt8] = []
        var index = input.startIndex

        while index < input.endIndex {
            let char = input[index]
            if char == "=" {
                let next1 = input.index(index, offsetBy: 1, limitedBy: input.endIndex)
                let next2 = next1.flatMap { input.index($0, offsetBy: 1, limitedBy: input.endIndex) }

                if let firstHexIndex = next1, next2 != nil {
                    // Decode two hex chars after "=" into a single byte.
                    let hexStr = String(input[firstHexIndex]) + String(input[input.index(after: firstHexIndex)])
                    if let byte = UInt8(hexStr, radix: 16) {
                        bytes.append(byte)
                        index = input.index(index, offsetBy: 3)
                        continue
                    }
                }
            }

            // Regular character
            for byte in String(char).utf8 {
                bytes.append(byte)
            }
            index = input.index(after: index)
        }

        return String(data: Data(bytes), encoding: encoding)
    }
}

// MARK: - String.Encoding helper

extension String.Encoding {
    /// Map a charset name to a String.Encoding.
    static func fromCharsetName(_ name: String) -> String.Encoding? {
        switch name.lowercased() {
            case "utf-8", "utf8":
                return .utf8
            case "iso-8859-1", "latin1", "iso_8859-1":
                return .isoLatin1
            case "iso-8859-2", "latin2", "iso_8859-2":
                return .isoLatin2
            case "us-ascii", "ascii":
                return .ascii
            case "windows-1252", "cp1252":
                return .windowsCP1252
            case "windows-1250", "cp1250":
                return .windowsCP1250
            case "iso-8859-15", "latin9", "iso_8859-15":
                return .isoLatin1 // Close enough
            default:
                return nil
        }
    }
}
