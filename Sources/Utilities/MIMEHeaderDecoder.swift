// MIMEHeaderDecoder.swift
// Utility functions for decoding MIME-encoded email headers

import Foundation

/// Utility functions for decoding MIME-encoded email headers
enum MIMEHeaderDecoder {
    /// Decode a MIME-encoded header string
    /// - Parameter encodedString: The MIME-encoded string to decode
    /// - Returns: The decoded string
    static func decode(_ encodedString: String) -> String {
        // Regular expression to match MIME encoded-word syntax: =?charset?encoding?encoded-text?=
        let pattern = "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?="
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return encodedString
        }
        
        var result = encodedString
        
        // Find all matches and process them in reverse order to avoid index issues
        let matches = regex.matches(in: encodedString, options: [], range: NSRange(encodedString.startIndex..., in: encodedString))
        
        for match in matches.reversed() {
            guard let charsetRange = Range(match.range(at: 1), in: encodedString),
                  let encodingRange = Range(match.range(at: 2), in: encodedString),
                  let textRange = Range(match.range(at: 3), in: encodedString),
                  let fullRange = Range(match.range, in: encodedString) else {
                continue
            }
            
            let charset = String(encodedString[charsetRange])
            let encoding = String(encodedString[encodingRange]).uppercased()
            let encodedText = String(encodedString[textRange])
            
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
    
    /// Decode quoted-printable content in message bodies
    /// - Parameter content: The content to decode
    /// - Returns: The decoded content
    public static func decodeQuotedPrintableContent(_ content: String) -> String {
        // Split the content into lines
        let lines = content.components(separatedBy: .newlines)
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
        if let decodedContent = content.decodeQuotedPrintable(encoding: contentEncoding) {
            return decodedContent
        }
        
        // Last resort: try with UTF-8
        return content.decodeQuotedPrintable() ?? content
    }
} 