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
            // For text content, try to extract and use the charset
            if part.contentType.lowercased().hasPrefix("text/"),
               let textContent = String(data: self, encoding: .utf8) {
                
                // Extract charset from Content-Type if available
                let charset = extractCharset(from: textContent) ?? "utf-8"
                
                // Try decoding with the specific charset first
                let encoding = String.encodingFromCharset(charset)
                if let decodedContent = textContent.decodeQuotedPrintable(encoding: encoding),
                   let decodedData = decodedContent.data(using: .utf8) {
                    return decodedData
                }
                
                // Fallback to simpler quoted-printable decoding
                let decodedContent = textContent.decodeQuotedPrintableContent()
                if let decodedData = decodedContent.data(using: .utf8) {
                    return decodedData
                }
            }
            
            // For non-text content or if text decoding failed
            if let rawContent = String(data: self, encoding: .ascii),
               let decoded = rawContent.decodeQuotedPrintableContent().data(using: .utf8) {
                return decoded
            }
            
            return self
            
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
    
    /// Extract the charset from a Content-Type header in the content
    /// - Parameter content: The content to search for charset
    /// - Returns: The charset if found, nil otherwise
    private func extractCharset(from content: String) -> String? {
        let contentTypePattern = "Content-Type:.*?charset=([^\\s;\"']+)"
        guard let range = content.range(of: contentTypePattern, options: .regularExpression),
              let charsetRange = content[range].range(of: "charset=([^\\s;\"']+)", options: .regularExpression) else {
            return nil
        }
        
        return content[charsetRange]
            .replacingOccurrences(of: "charset=", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
    }
}

extension Data {
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