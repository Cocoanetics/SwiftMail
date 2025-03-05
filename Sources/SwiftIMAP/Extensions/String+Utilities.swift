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
	
	// Helper function to get MIME type from file URL using UTI
	static func mimeType(for fileExtension: String) -> String {
		// First try to get UTType from file extension
		
		if let utType = UTType(filenameExtension: fileExtension) {
			// If we have a UTType, try to get its MIME type
			if let mimeType = utType.preferredMIMEType {
				return mimeType
			}
		}
		
		
		// Fallback to common extensions if UTI doesn't work
		let pathExtension = fileExtension.lowercased()
		switch pathExtension {
		case "jpg", "jpeg":
			return "image/jpeg"
		case "png":
			return "image/png"
		case "gif":
			return "image/gif"
		case "svg":
			return "image/svg+xml"
		case "pdf":
			return "application/pdf"
		case "txt":
			return "text/plain"
		case "html", "htm":
			return "text/html"
		case "doc", "docx":
			return "application/msword"
		case "xls", "xlsx":
			return "application/vnd.ms-excel"
		case "zip":
			return "application/zip"
		default:
			return "application/octet-stream"
		}
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
