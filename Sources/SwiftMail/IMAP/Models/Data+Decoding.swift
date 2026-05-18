import Foundation

extension Data {
    /// Decode the data based on the message part's content type and encoding
    /// - Parameter part: The message part containing content type and encoding information
    /// - Returns: The decoded data, or the original data if decoding is not needed or fails
    /// - Note: Handles standard MIME content transfer encodings (7bit, 8bit, binary, quoted-printable, base64)
    public func decoded(for part: MessagePart) -> Data {
        // If no encoding specified, treat as binary/8bit/7bit (no decoding needed)
        guard let encoding = part.encoding?.lowercased() else {
            return self
        }

        switch encoding {
        case "7bit", "8bit", "binary":
            // These encodings don't require transformation
            return self

        case "quoted-printable":
            // Decode transfer-encoding only; keep original charset bytes intact.
            // This avoids early String transcoding (e.g. ISO-8859-1 -> UTF-8) and lets
            // callers decode to String exactly once at the point of consumption.
            return quotedPrintableTransferDecodedData()

        case "base64":
            // First try decoding the raw data
            if let decoded = self.base64DecodedData() {
                return decoded
            }

            // If that fails, try cleaning up the string and decode
            if let base64String = String(data: self, encoding: .utf8) {
                let normalized = base64String
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: " ", with: "")

                if let decoded = Data(base64Encoded: normalized) {
                    return decoded
                }

                // Try with padding if needed
                let padded = normalized.padding(
                    toLength: ((normalized.count + 3) / 4) * 4,
                    withPad: "=",
                    startingAt: 0
                )
                if let decoded = Data(base64Encoded: padded) {
                    return decoded
                }
            }

            return self

        default:
            return self
        }
    }
}

extension Data {
    /// Decode quoted-printable transfer encoding into raw bytes.
    ///
    /// Important: this method intentionally does **not** apply charset decoding.
    /// It only reverses the MIME transfer encoding layer and preserves original
    /// text bytes (e.g. ISO-8859-1 bytes remain ISO-8859-1 bytes).
    fileprivate func quotedPrintableTransferDecodedData() -> Data {
        var output = Data(capacity: count)
        let bytes = [UInt8](self)
        var i = 0

        @inline(__always)
        func hexNibble(_ value: UInt8) -> UInt8? {
            switch value {
            case 48...57: return value - 48      // 0-9
            case 65...70: return value - 55      // A-F
            case 97...102: return value - 87     // a-f
            default: return nil
            }
        }

        while i < bytes.count {
            let current = bytes[i]

            // '=' introduces either soft-line-break or hex-escaped octet.
            if current == UInt8(ascii: "=") {
                // Soft line break: =\r\n
                if i + 2 < bytes.count,
                   bytes[i + 1] == UInt8(ascii: "\r"),
                   bytes[i + 2] == UInt8(ascii: "\n") {
                    i += 3
                    continue
                }

                // Soft line break: =\n
                if i + 1 < bytes.count,
                   bytes[i + 1] == UInt8(ascii: "\n") {
                    i += 2
                    continue
                }

                // Hex escaped octet: =XX
                if i + 2 < bytes.count,
                   let hi = hexNibble(bytes[i + 1]),
                   let lo = hexNibble(bytes[i + 2]) {
                    output.append((hi << 4) | lo)
                    i += 3
                    continue
                }
            }

            // Literal byte (also used as lossy fallback for malformed sequences).
            output.append(current)
            i += 1
        }

        return output
    }

    /// Attempt to decode the data as base64 directly
    /// - Returns: Decoded data if successful, nil otherwise
    fileprivate func base64DecodedData() -> Data? {
        // Check if the data is valid base64
        var options = Data.Base64DecodingOptions()
        if let decoded = Data(base64Encoded: self, options: options) {
            return decoded
        }

        // Try ignoring invalid characters
        options.insert(.ignoreUnknownCharacters)
        return Data(base64Encoded: self, options: options)
    }
}
