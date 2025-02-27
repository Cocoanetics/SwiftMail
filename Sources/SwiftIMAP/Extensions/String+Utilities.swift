// String+Utilities.swift
// Extensions for String to handle IMAP-related utilities

import Foundation
import NIOIMAPCore
import UniformTypeIdentifiers

extension String {
    /// Sanitize a filename to ensure it's valid
    /// - Returns: A sanitized filename
    func sanitizedFileName() -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return self
            .components(separatedBy: invalidCharacters)
            .joined(separator: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
    
    /// Get a file extension for a given MIME type
    /// - Parameter mimeType: The full MIME type (e.g., "text/plain", "image/jpeg")
    /// - Returns: An appropriate file extension (without the dot)
	static func fileExtension(for mimeType: String) -> String? {
		// Try to get the UTType from the MIME type
		if let utType = UTType(mimeType: mimeType) {
			// Get the preferred file extension
			if let preferredExtension = utType.preferredFilenameExtension {
				return preferredExtension
			}
		}
		
		return nil
	}
	
    /// Parse a string range (e.g., "1:10") into a SequenceSet
    /// - Returns: A SequenceSet object
    /// - Throws: An error if the range string is invalid
    func toSequenceSet() throws -> NIOIMAPCore.MessageIdentifierSetNonEmpty<NIOIMAPCore.SequenceNumber> {
        // Split the range by colon
        let parts = self.split(separator: ":")
        
        if parts.count == 1, let number = UInt32(parts[0]) {
            // Single number
            let sequenceNumber = SequenceNumber(number)
            let set = SequenceNumberSet(sequenceNumber)
            return set.toNIOSet()!
        } else if parts.count == 2, let start = UInt32(parts[0]), let end = UInt32(parts[1]) {
            // Range
            let startSeq = SequenceNumber(start)
            let endSeq = SequenceNumber(end)
            let set = SequenceNumberSet(startSeq...endSeq)
            return set.toNIOSet()!
        } else {
            throw IMAPError.invalidArgument("Invalid sequence range: \(self)")
        }
    }
} 
