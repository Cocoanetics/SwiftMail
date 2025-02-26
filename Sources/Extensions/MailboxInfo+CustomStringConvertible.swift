// MailboxInfo+CustomStringConvertible.swift
// Extension for MailboxInfo to conform to CustomStringConvertible

import Foundation

extension MailboxInfo: CustomStringConvertible {
    /// A string representation of the mailbox information
    public var description: String {
        return """
        Mailbox: \(name)
        Messages: \(messageCount)
        Recent: \(recentCount)
        Unseen: \(unseenCount)
        First Unseen: \(firstUnseen > 0 ? String(firstUnseen) : "N/A")
        UID Validity: \(uidValidity)
        UID Next: \(uidNext)
        Read-Only: \(isReadOnly ? "Yes" : "No")
        Available Flags: \(availableFlags.joined(separator: ", "))
        Permanent Flags: \(permanentFlags.joined(separator: ", "))
        """
    }
} 