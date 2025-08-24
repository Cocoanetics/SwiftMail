import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import CoreFoundation
#endif

extension String {
    /// Encodes the string using quoted-printable encoding
    public func quotedPrintableEncoded() -> String {
        var encoded = ""
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!*+-/=_ ")

        for char in utf8 {
            if allowedCharacters.contains(UnicodeScalar(char)) && char != UInt8(ascii: " ") {
                encoded.append(Character(UnicodeScalar(char)))
            } else if char == UInt8(ascii: " ") {
                encoded.append("_")
            } else {
                encoded.append(String(format: "=%02X", char))
            }
        }

        return encoded
    }

    /// Decodes a quoted-printable encoded string by removing "soft line
    /// breaks" and replacing all quoted-printable escape sequences with the
    /// matching characters as determined by a given encoding.
    /// - parameter enc: A string encoding. The default is UTF-8.
    /// - returns: The decoded string, or `nil` for invalid input.
    public func decodeQuotedPrintable(encoding enc: String.Encoding = .utf8) -> String? {
        // Remove soft line breaks (=<CR><LF>)
        let withoutSoftBreaks = self.replacingOccurrences(of: "=\r\n", with: "")
            .replacingOccurrences(of: "=\n", with: "")
        
        var result = ""
        var index = withoutSoftBreaks.startIndex
        var bytes: [UInt8] = []
        
        while index < withoutSoftBreaks.endIndex {
            let char = withoutSoftBreaks[index]
            
            if char == "=" {
                // Check if we have enough characters for a hex sequence
                let nextIndex = withoutSoftBreaks.index(after: index)
                guard nextIndex < withoutSoftBreaks.endIndex,
                      let nextNextIndex = withoutSoftBreaks.index(nextIndex, offsetBy: 1, limitedBy: withoutSoftBreaks.endIndex) else {
                    return nil // Invalid encoding
                }
                
                // Get the two hex characters
                let hex = String(withoutSoftBreaks[nextIndex...nextNextIndex])
                
                // Convert hex to byte
                guard let byte = UInt8(hex, radix: 16) else {
                    return nil // Invalid hex sequence
                }
                
                bytes.append(byte)
                index = withoutSoftBreaks.index(after: nextNextIndex)
            } else {
                // If we have collected bytes, try to decode them
                if !bytes.isEmpty {
                    if let decodedChar = String(bytes: bytes, encoding: enc) {
                        result.append(decodedChar)
                    } else {
                        return nil // Invalid byte sequence
                    }
                    bytes.removeAll()
                }
                
                result.append(char)
                index = withoutSoftBreaks.index(after: index)
            }
        }
        
        // Handle any remaining bytes
        if !bytes.isEmpty {
            if let decodedChar = String(bytes: bytes, encoding: enc) {
                result.append(decodedChar)
            } else {
                return nil // Invalid byte sequence
            }
        }
        
        return result
    }

    /// Decode a MIME-encoded header string
    /// - Returns: The decoded string
    public func decodeMIMEHeader() -> String {
        // Regular expression to match MIME encoded-word syntax: =?charset?encoding?encoded-text?=
        let pattern = "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?="
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return self
        }
        
        var result = self
        
        // Find all matches and process them in reverse order to avoid index issues
        let matches = regex.matches(in: self, options: [], range: NSRange(self.startIndex..., in: self))
        
        for match in matches.reversed() {
            guard let charsetRange = Range(match.range(at: 1), in: self),
                  let encodingRange = Range(match.range(at: 2), in: self),
                  let textRange = Range(match.range(at: 3), in: self),
                  let fullRange = Range(match.range, in: self) else {
                continue
            }
            
            let charset = String(self[charsetRange])
            let encoding = String(self[encodingRange]).uppercased()
            let encodedText = String(self[textRange])
            
            var decodedText = ""
            
            // Convert charset to String.Encoding
            let stringEncoding = String.encodingFromCharset(charset)
            
            // Decode based on encoding type
            if encoding == "B" {
                // Base64 encoding
                if let data = Data(base64Encoded: encodedText, options: .ignoreUnknownCharacters),
                   let decoded = String(data: data, encoding: stringEncoding) {
                    decodedText = decoded
                } else {
                    // Try with UTF-8 if the specified charset fails
                    if let data = Data(base64Encoded: encodedText, options: .ignoreUnknownCharacters),
                       let decoded = String(data: data, encoding: .utf8) {
                        decodedText = decoded
                    }
                }
            } else if encoding == "Q" {
                // Quoted-printable encoding
                if let decoded = encodedText.decodeQuotedPrintable(encoding: stringEncoding) {
                    decodedText = decoded
                } else if let decoded = encodedText.decodeQuotedPrintable() {
                    // Fallback to UTF-8 if the specified charset fails
                    decodedText = decoded
                }
            }
            
            if !decodedText.isEmpty {
                result = result.replacingCharacters(in: fullRange, with: decodedText)
            }
        }
        
        // Handle consecutive encoded words (they should be concatenated without spaces)
        result = result.replacingOccurrences(of: "?= =?", with: "")
        
        return result
    }

    /// Detects the charset from content and returns the appropriate String.Encoding
    /// - Returns: The detected String.Encoding, or .utf8 as fallback
    public func detectCharsetEncoding() -> String.Encoding {
        // Look for Content-Type header with charset
        let contentTypePattern = "Content-Type:.*?charset=([^\\s;\"']+)"
        if let range = self.range(of: contentTypePattern, options: .regularExpression, range: nil, locale: nil),
           let charsetRange = self[range].range(of: "charset=([^\\s;\"']+)", options: .regularExpression) {
            let charsetString = self[charsetRange].replacingOccurrences(of: "charset=", with: "")
            return String.encodingFromCharset(charsetString)
        }
        
        // Look for meta tag with charset
        let metaPattern = "<meta[^>]*charset=([^\\s;\"'/>]+)"
        if let range = self.range(of: metaPattern, options: .regularExpression, range: nil, locale: nil),
           let charsetRange = self[range].range(of: "charset=([^\\s;\"'/>]+)", options: .regularExpression) {
            let charsetString = self[charsetRange].replacingOccurrences(of: "charset=", with: "")
            return String.encodingFromCharset(charsetString)
        }
        
        // Default to UTF-8
        return .utf8
    }
    
    /// Decode quoted-printable content in message bodies
    /// - Returns: The decoded content
    public func decodeQuotedPrintableContent() -> String {
        // Split the content into lines
        let lines = self.components(separatedBy: .newlines)
        var inBody = false
        var bodyContent = ""
        var headerContent = ""
        var contentEncoding: String.Encoding = .utf8
        
        // Process each line
        for line in lines {
            if !inBody {
                // Check if we've reached the end of headers
                if line.isEmpty {
                    inBody = true
                    headerContent += line + "\n"
                    continue
                }
                
                // Add header line
                headerContent += line + "\n"
                
                // Check for Content-Type header with charset
                if line.lowercased().contains("content-type:") && line.lowercased().contains("charset=") {
                    if let range = line.range(of: "charset=([^\\s;\"']+)", options: .regularExpression) {
                        let charsetString = line[range].replacingOccurrences(of: "charset=", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\"", with: "")
                            .replacingOccurrences(of: "'", with: "")
                        contentEncoding = String.encodingFromCharset(charsetString)
                    }
                }
                
                // Check if this is a Content-Transfer-Encoding header
                if line.lowercased().contains("content-transfer-encoding:") && 
                   line.lowercased().contains("quoted-printable") {
                    // Found quoted-printable encoding
                    inBody = false
                }
            } else {
                // Add body line
                bodyContent += line + "\n"
            }
        }
        
        // If we found quoted-printable encoding, decode the body
        if !bodyContent.isEmpty {
            // Decode the body content with the detected encoding
            if let decodedBody = bodyContent.decodeQuotedPrintable(encoding: contentEncoding) {
                return headerContent + decodedBody
            } else if let decodedBody = bodyContent.decodeQuotedPrintable() {
                // Fallback to UTF-8 if the specified charset fails
                return headerContent + decodedBody
            }
        }
        
        // If we didn't find quoted-printable encoding or no body content,
        // try to decode the entire content with the detected charset
        if let decodedContent = self.decodeQuotedPrintable(encoding: contentEncoding) {
            return decodedContent
        }
        
        // Last resort: try with UTF-8
        return self.decodeQuotedPrintable() ?? self
    }
}

 
