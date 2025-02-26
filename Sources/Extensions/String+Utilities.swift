// String+Utilities.swift
// Extensions for String to handle IMAP-related utilities

import Foundation
import NIOIMAPCore

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
    
    /// Get a file extension based on content type and subtype
    /// - Parameter subtype: The content subtype
    /// - Returns: An appropriate file extension
    func fileExtension(subtype: String) -> String {
        let type = self.lowercased()
        let sub = subtype.lowercased()
        
        switch (type, sub) {
        case ("text", "plain"):
            return "txt"
        case ("text", "html"):
            return "html"
        case ("text", _):
            return "txt"
        case ("image", "jpeg"), ("image", "jpg"):
            return "jpg"
        case ("image", "png"):
            return "png"
        case ("image", "gif"):
            return "gif"
        case ("image", _):
            return "img"
        case ("application", "pdf"):
            return "pdf"
        case ("application", "json"):
            return "json"
        case ("application", "javascript"):
            return "js"
        case ("application", "zip"):
            return "zip"
        case ("application", _):
            return "bin"
        case ("audio", "mp3"):
            return "mp3"
        case ("audio", "wav"):
            return "wav"
        case ("audio", _):
            return "audio"
        case ("video", "mp4"):
            return "mp4"
        case ("video", _):
            return "video"
        default:
            return "dat"
        }
    }
    
    /// Parse a string range (e.g., "1:10") into a SequenceSet
    /// - Returns: A SequenceSet object
    /// - Throws: An error if the range string is invalid
    func toSequenceSet() throws -> MessageIdentifierSetNonEmpty<SequenceNumber> {
        // Split the range by colon
        let parts = self.split(separator: ":")
        
        if parts.count == 1, let number = UInt32(parts[0]) {
            // Single number
            let sequenceNumber = SequenceNumber(rawValue: number)
            let set = MessageIdentifierSet<SequenceNumber>(sequenceNumber)
            return MessageIdentifierSetNonEmpty(set: set)!
        } else if parts.count == 2, let start = UInt32(parts[0]), let end = UInt32(parts[1]) {
            // Range
            let startSeq = SequenceNumber(rawValue: start)
            let endSeq = SequenceNumber(rawValue: end)
            let range = MessageIdentifierRange(startSeq...endSeq)
            return MessageIdentifierSetNonEmpty(range: range)
        } else {
            throw IMAPError.invalidArgument("Invalid sequence range: \(self)")
        }
    }
} 