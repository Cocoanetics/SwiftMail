// String+Utilities.swift
// General utility extensions for String

import Foundation

extension String {
    /// Sanitize a filename to ensure it's valid
    /// - Returns: A sanitized filename
    public func sanitizedFileName() -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return self
            .components(separatedBy: invalidCharacters)
            .joined(separator: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
} 