// String+Utilities.swift
// General utility extensions for String

import Foundation

extension String {
    /// Sanitize a filename to ensure it's valid for most file systems.
    ///
    /// This removes disallowed characters while leaving all whitespace
    /// untouched so that a filename such as "my document.pdf" remains user
    /// friendly.
    /// - Returns: A sanitized filename that is safe to write to disk
    public func sanitizedFileName() -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return self
            .components(separatedBy: invalidCharacters)
            .joined()
    }
}
