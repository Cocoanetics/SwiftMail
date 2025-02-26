// MailboxInfo.swift
// Structure to hold information about a mailbox

import Foundation

/// Structure to hold information about a mailbox
public struct MailboxInfo: Sendable {
    /// The name of the mailbox
    public let name: String
    
    /// The total number of messages in the mailbox
    public var messageCount: Int = 0
    
    /// The number of recent messages in the mailbox
    /// Note: In IMAP, "recent" messages are those that have been delivered since the last time
    /// any client selected this mailbox. This is different from "unseen" messages.
    /// A value of 0 is normal if you've accessed this mailbox recently with another client,
    /// or if no new messages have arrived since the last time the mailbox was selected.
    public var recentCount: Int = 0
    
    /// The number of unseen messages in the mailbox
    public var unseenCount: Int = 0
    
    /// The sequence number of the first unseen message
    public var firstUnseen: Int = 0
    
    /// The UID validity value for the mailbox
    /// Note: This is a number that changes when the mailbox's UID numbering is reset.
    /// It's used by clients to determine if their cached UIDs are still valid.
    /// A value of 1 is perfectly valid - it just means this is the first UID numbering scheme for this mailbox.
    public var uidValidity: UInt32 = 0
    
    /// The next UID value for the mailbox
    public var uidNext: UInt32 = 0
    
    /// Whether the mailbox is read-only
    public var isReadOnly: Bool = false
    
    /// The flags available in the mailbox
    public var availableFlags: [String] = []
    
    /// The flags that can be permanently stored
    public var permanentFlags: [String] = []
    
    /// Initialize a new mailbox info structure
    /// - Parameter name: The name of the mailbox
    public init(name: String) {
        self.name = name
    }
} 