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