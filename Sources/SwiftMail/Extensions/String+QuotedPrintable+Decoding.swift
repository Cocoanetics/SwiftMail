// String+QuotedPrintable+Decoding.swift
// Quoted-Printable decoding logic split off from the main file.

import Foundation

extension String {
    /// Decodes a quoted-printable encoded string by removing "soft line" breaks and replacing all
    /// quoted-printable escape sequences with the matching characters.
    /// - Returns: The decoded string, or `nil` for invalid input.
    public func decodeQuotedPrintable() -> String? {
        if let decoded = decodeQuotedPrintable(encoding: .utf8) {
            return decoded
        }
        return decodeQuotedPrintable(encoding: .isoLatin1)
    }

    /// Decodes a quoted-printable encoded string but tolerates invalid sequences by leaving them as-is
    /// in the output. This is useful for handling real-world messages that might contain malformed
    /// quoted-printable data.
    /// - Returns: The decoded string with invalid sequences preserved.
    public func decodeQuotedPrintableLossy() -> String {
        return decodeQuotedPrintableLossy(encoding: .utf8)
    }

    /// Decodes a quoted-printable encoded string with a specific encoding
    /// - Parameter enc: The target string encoding. The default is UTF-8.
    /// - Returns: The decoded string, or `nil` for invalid input.
    public func decodeQuotedPrintable(encoding enc: String.Encoding) -> String? {
        // Remove soft line breaks (=<CR><LF> or =<LF>)
        let withoutSoftBreaks = self.replacingOccurrences(of: "=\r\n", with: "")
            .replacingOccurrences(of: "=\n", with: "")

        var bytes = Data()
        var index = withoutSoftBreaks.startIndex

        while index < withoutSoftBreaks.endIndex {
            let char = withoutSoftBreaks[index]

            if char == "=" {
                let nextIndex = withoutSoftBreaks.index(after: index)
                guard nextIndex < withoutSoftBreaks.endIndex else {
                    return nil
                }
                let nextNextIndex = withoutSoftBreaks.index(after: nextIndex)
                guard nextNextIndex < withoutSoftBreaks.endIndex else {
                    return nil
                }
                let hex = String(withoutSoftBreaks[nextIndex...nextNextIndex])
                guard let byte = UInt8(hex, radix: 16) else {
                    return nil
                }
                bytes.append(byte)
                index = withoutSoftBreaks.index(after: nextNextIndex)
            } else {
                if let ascii = char.asciiValue {
                    bytes.append(ascii)
                } else if let data = String(char).data(using: enc) {
                    bytes.append(contentsOf: data)
                }
                index = withoutSoftBreaks.index(after: index)
            }
        }

        return String(data: bytes, encoding: enc)
    }

    /// Decodes a quoted-printable encoded string with a specific encoding, tolerating invalid sequences
    /// by preserving them in the output.
    /// - Parameter enc: The target string encoding. The default is UTF-8.
    /// - Returns: The decoded string with invalid sequences preserved.
    public func decodeQuotedPrintableLossy(encoding enc: String.Encoding) -> String {
        // Remove soft line breaks
        let withoutSoftBreaks = self.replacingOccurrences(of: "=\r\n", with: "")
            .replacingOccurrences(of: "=\n", with: "")

        var bytes = Data()
        var index = withoutSoftBreaks.startIndex

        while index < withoutSoftBreaks.endIndex {
            let char = withoutSoftBreaks[index]

            if char == "=" {
                let nextIndex = withoutSoftBreaks.index(after: index)
                if nextIndex < withoutSoftBreaks.endIndex {
                    let nextNextIndex = withoutSoftBreaks.index(after: nextIndex)
                    if nextNextIndex < withoutSoftBreaks.endIndex {
                        let hex = String(withoutSoftBreaks[nextIndex...nextNextIndex])
                        if let byte = UInt8(hex, radix: 16) {
                            bytes.append(byte)
                            index = withoutSoftBreaks.index(after: nextNextIndex)
                            continue
                        }
                    }
                }
                // Invalid or incomplete sequence: treat '=' literally
                bytes.append(UInt8(ascii: "="))
                index = withoutSoftBreaks.index(after: index)
            } else {
                if let ascii = char.asciiValue {
                    bytes.append(ascii)
                } else if let data = String(char).data(using: enc) {
                    bytes.append(contentsOf: data)
                }
                index = withoutSoftBreaks.index(after: index)
            }
        }

        // Lossy fallback preserves QP-decoded bytes that don't match the declared charset;
        // dropping the message would lose readable content from misdeclared encodings.
        // swiftlint:disable:next optional_data_string_conversion
        return String(data: bytes, encoding: enc) ?? String(decoding: bytes, as: UTF8.self)
    }
}
