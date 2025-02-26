// MessagePart+CustomStringConvertible.swift
// Extension for MessagePart to conform to CustomStringConvertible

import Foundation

extension MessagePart: CustomStringConvertible {
    /// A string representation of the message part
    public var description: String {
        return """
        Part #\(partNumber)
        Content-Type: \(contentType)/\(contentSubtype)
        \(disposition != nil ? "Content-Disposition: \(disposition!)" : "")
        \(filename != nil ? "Filename: \(filename!)" : "")
        \(contentId != nil ? "Content-ID: \(contentId!)" : "")
        Size: \(size) bytes
        """
    }
} 