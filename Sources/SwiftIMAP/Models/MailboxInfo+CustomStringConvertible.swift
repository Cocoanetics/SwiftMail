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
        Available Flags: \(formatFlags(availableFlags))
        Permanent Flags: \(formatFlags(permanentFlags))
        """
    }
    
    /// Format flags for display
    private func formatFlags(_ flags: [MessageFlag]) -> String {
        return flags.map { flag -> String in
            switch flag {
            case .seen:
                return "\\Seen"
            case .answered:
                return "\\Answered"
            case .flagged:
                return "\\Flagged"
            case .deleted:
                return "\\Deleted"
            case .draft:
                return "\\Draft"
            case .custom(let name):
                return name
            }
        }.joined(separator: ", ")
    }
} 