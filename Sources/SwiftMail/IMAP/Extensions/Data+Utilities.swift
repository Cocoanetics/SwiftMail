// Data+Utilities.swift
// Extensions for Data to handle MIME-related utilities

import Foundation

extension Data {
    /// Create a preview of the data content
    /// - Parameter maxLength: The maximum length of the preview
    /// - Returns: A string preview of the content
    func preview(maxLength: Int = 500) -> String {
        if let text = String(data: self, encoding: .utf8) {
            let truncated = text.prefix(maxLength)
            return String(truncated)
        } else if self.count > 0 {
            return "<Binary data: \(self.count.formattedFileSize())>"
        } else {
            return "<Empty data>"
        }
    }
    
    /// Check if the data appears to be text content
    /// - Returns: True if the data appears to be text, false otherwise
    func isTextContent() -> Bool {
        // Check if the data can be converted to a string
        guard let _ = String(data: self, encoding: .utf8) else {
            return false
        }
        
        // Check for common binary file signatures
        if self.count >= 4 {
            let bytes = [UInt8](self.prefix(4))
            
            // Check for common binary file signatures
            if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { // JPEG
                return false
            }
            if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { // PNG
                return false
            }
            if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { // GIF
                return false
            }
            if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) { // PDF
                return false
            }
            if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { // ZIP
                return false
            }
        }
        
        return true
    }
    
    /// Decode the data based on the message part's content type and encoding
    /// - Parameter part: The message part containing content type and encoding information
    /// - Returns: The decoded data, or the original data if decoding is not needed or fails
    public func decoded(for part: MessagePart) -> Data {
        // For text content, try to handle quoted-printable encoding
        if part.contentType.lowercased().hasPrefix("text/"),
           let textContent = String(data: self, encoding: .utf8) {
            
            // Check for Content-Transfer-Encoding header in the part data
            let isQuotedPrintable = textContent.contains("Content-Transfer-Encoding: quoted-printable") ||
                                   textContent.contains("Content-Transfer-Encoding:quoted-printable") ||
                                   textContent.contains("=3D") || // Common quoted-printable pattern
                                   textContent.contains("=\r\n") || // Soft line break
                                   textContent.contains("=\n")    // Soft line break
            
            if isQuotedPrintable {
                // Extract charset from Content-Type header if available
                var charset = "utf-8" // Default charset
                let contentTypePattern = "Content-Type:.*?charset=([^\\s;\"']+)"
                if let range = textContent.range(of: contentTypePattern, options: .regularExpression, range: nil, locale: nil),
                   let charsetRange = textContent[range].range(of: "charset=([^\\s;\"']+)", options: .regularExpression) {
                    charset = String(textContent[charsetRange].replacingOccurrences(of: "charset=", with: ""))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\"", with: "")
                        .replacingOccurrences(of: "'", with: "")
                }
                
                // Use the extracted charset for decoding
                let encoding = String.encodingFromCharset(charset)
                if let decodedContent = textContent.decodeQuotedPrintable(encoding: encoding),
                   let decodedData = decodedContent.data(using: .utf8) {
                    return decodedData
                } else {
                    // Fallback to the String extension if specific charset decoding fails
                    let decodedContent = textContent.decodeQuotedPrintableContent()
                    if let decodedData = decodedContent.data(using: .utf8) {
                        return decodedData
                    }
                }
            }
        }
        
        // For base64 encoded content
        if part.encoding?.lowercased() == "base64",
           let base64String = String(data: self, encoding: .utf8) {
            let normalized = base64String.replacingOccurrences(of: "\r", with: "")
                                       .replacingOccurrences(of: "\n", with: "")
            
            if let decoded = Data(base64Encoded: normalized) {
                return decoded
            }
        }
        
        // Return original data if no decoding was needed or possible
        return self
    }
} 
