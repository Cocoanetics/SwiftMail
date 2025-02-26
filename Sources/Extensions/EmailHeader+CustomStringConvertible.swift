// EmailHeader+CustomStringConvertible.swift
// Extension for EmailHeader to conform to CustomStringConvertible

import Foundation

extension EmailHeader: CustomStringConvertible {
    /// A string representation of the email header
    public var description: String {
        return """
        Message #\(sequenceNumber) (UID: \(uid > 0 ? String(uid) : "N/A"))
        Subject: \(subject)
        From: \(from)
        Date: \(date)
        Flags: \(flags.joined(separator: ", "))
        """
    }
} 