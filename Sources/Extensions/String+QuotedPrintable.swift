//
//  String+QuotedPrintable.swift
//  SwiftIMAP
//
//  Created by Oliver Drobnik on 25.02.25.
//

import Foundation

extension String {

	/// Returns a new string made by removing in the `String` all "soft line
	/// breaks" and replacing all quoted-printable escape sequences with the
	/// matching characters as determined by a given encoding.
	/// - parameter encoding:     A string encoding. The default is UTF-8.
	/// - returns:                The decoded string, or `nil` for invalid input.

	func decodeQuotedPrintable(encoding enc : String.Encoding = .utf8) -> String? {

		// Handle soft line breaks, then replace quoted-printable escape sequences.
		return self
			.replacingOccurrences(of: "=\r\n", with: "")
			.replacingOccurrences(of: "=\n", with: "")
			.decodeQuotedPrintableSequences(encoding: enc)
	}
	
	/// Detects the charset from content and returns the appropriate String.Encoding
	/// - Returns: The detected String.Encoding, or .utf8 as fallback
	func detectCharsetEncoding() -> String.Encoding {
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
	
	/// Decodes quoted-printable content with automatic charset detection
	/// - Returns: The decoded string, or `nil` for invalid input
	func decodeQuotedPrintableWithAutoDetection() -> String? {
		let encoding = self.detectCharsetEncoding()
		return self.decodeQuotedPrintable(encoding: encoding)
	}

	/// Helper function doing the real work.
	/// Decode all "=HH" sequences with respect to the given encoding.
	private func decodeQuotedPrintableSequences(encoding enc : String.Encoding) -> String? {

		var result = ""
		var position = startIndex

		// Find the next "=" and copy characters preceding it to the result:
		while let range = range(of: "=", range: position..<endIndex) {
			result.append(contentsOf: self[position ..< range.lowerBound])
			position = range.lowerBound

			// Decode one or more successive "=HH" sequences to a byte array:
			var bytes = Data()
			repeat {
				let hexCode = self[position...].dropFirst().prefix(2)
				if hexCode.count < 2 {
					return nil // Incomplete hex code
				}
				guard let byte = UInt8(hexCode, radix: 16) else {
					return nil // Invalid hex code
				}
				bytes.append(byte)
				position = index(position, offsetBy: 3)
			} while position != endIndex && self[position] == "="

			// Convert the byte array to a string, and append it to the result:
			guard let dec = String(data: bytes, encoding: enc) else {
				// If the specified encoding fails, try with UTF-8 as fallback
				if enc != .utf8, let fallbackDec = String(data: bytes, encoding: .utf8) {
					result.append(contentsOf: fallbackDec)
				} else {
					return nil // Decoded bytes not valid in any encoding
				}
				continue
			}
			result.append(contentsOf: dec)
		}

		// Copy remaining characters to the result:
		result.append(contentsOf: self[position ..< endIndex])

		return result
	}
    
    /// Decode a MIME-encoded header string
    /// - Returns: The decoded string
    func decodeMIMEHeader() -> String {
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
    
    /// Decode quoted-printable content in message bodies
    /// - Returns: The decoded content
    func decodeQuotedPrintableContent() -> String {
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

// MARK: - String.Encoding Helpers

extension String {
	/// Convert a charset string to a String.Encoding
	/// - Parameter charset: The charset name (e.g., "utf-8", "iso-8859-1")
	/// - Returns: The corresponding String.Encoding, or .utf8 as fallback
	static func encodingFromCharset(_ charset: String) -> String.Encoding {
		let normalizedCharset = charset.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		
		// Handle common charset names directly
		switch normalizedCharset {
		case "utf-8", "utf8":
			return .utf8
		case "iso-8859-1", "iso8859-1", "latin1":
			return .isoLatin1
		case "iso-8859-2", "iso8859-2", "latin2":
			return .isoLatin2
		case "windows-1252", "cp1252":
			return .windowsCP1252
		case "ascii":
			return .ascii
		case "utf-16", "utf16":
			return .utf16
		case "utf-16be", "utf16be":
			return .utf16BigEndian
		case "utf-16le", "utf16le":
			return .utf16LittleEndian
		default:
			// Try to convert using Core Foundation
			let cfEncoding = CFStringConvertIANACharSetNameToEncoding(normalizedCharset as CFString)
			if cfEncoding != kCFStringEncodingInvalidId {
				let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
				return String.Encoding(rawValue: nsEncoding)
			}
			
			// Default to UTF-8 if charset is not recognized
			return .utf8
		}
	}
} 