// String+Redacting.swift
// String extensions for the SwiftMailCore library

import Foundation

extension String {
	/// Redacts sensitive information that appears after the specified keyword
	/// For example, "A002 LOGIN username password" becomes "A002 LOGIN [credentials redacted]"
	/// or "AUTH PLAIN base64data" becomes "AUTH [credentials redacted]"
	/// - Parameter keyword: The keyword to look for (e.g., "LOGIN" or "AUTH")
	/// - Returns: The redacted string, or the original string if no redaction was needed
	public func redactAfter(_ keyword: String) -> String {
		// Create a regex pattern that matches IMAP commands in both formats:
		// 1. With a tag: tag + command (e.g., "A001 LOGIN")
		// 2. Without a tag: just the command (e.g., "AUTH PLAIN")
		let pattern = "(^\\s*\\w+\\s+\(keyword)\\b|^\\s*\(keyword)\\b)"
		
		do {
			let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
			let range = NSRange(location: 0, length: self.utf16.count)
			
			// If we find a match, proceed with redaction
			if let match = regex.firstMatch(in: self, options: [], range: range) {
				// Convert the NSRange back to a String.Index range
				guard let keywordRange = Range(match.range, in: self) else {
					return self
				}
				
				// Find the end of the keyword/command
				let keywordEnd = keywordRange.upperBound
				
				// Check if there's content after the keyword/command
				guard keywordEnd < self.endIndex else {
					// If the keyword is at the end, return the original string
					return self
				}
				
				// Create the redacted string: preserve everything up to the keyword/command (inclusive)
				let preservedPart = self[..<keywordEnd]
				
				return "\(preservedPart) [credentials redacted]"
			} else {
				// No match found, return the original string
				return self
			}
		} catch {
			// If regex creation fails, fall back to the simple substring search
			guard let keywordRange = self.range(of: keyword, options: [.caseInsensitive]) else {
				return self
			}
			
			let keywordEnd = keywordRange.upperBound
			
			guard keywordEnd < self.endIndex else {
				return self
			}
			
			let preservedPart = self[..<keywordEnd]
			
			return "\(preservedPart) [credentials redacted]"
		}
	}
}
