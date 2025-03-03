import Foundation
import NIOIMAPCore

/// Represents an IMAP mailbox
public struct Mailbox {
    /// Information about a mailbox from a LIST command
    public struct Info: Sendable {
        /// The name of the mailbox
        public let name: String
        
        /// The attributes of the mailbox
        public let attributes: MailboxAttributes
        
        /// The hierarchy delimiter used by the server
        public let hierarchyDelimiter: Character?
        
        /// Initialize from NIOIMAPCore.MailboxInfo
        public init(from info: NIOIMAPCore.MailboxInfo) {
            self.name = String(decoding: info.path.name.bytes, as: UTF8.self)
            self.attributes = MailboxAttributes(from: Array(info.attributes))
            self.hierarchyDelimiter = info.path.pathSeparator
        }
        
        /// Initialize with raw values
        public init(name: String, attributes: MailboxAttributes, hierarchyDelimiter: Character?) {
            self.name = name
            self.attributes = attributes
            self.hierarchyDelimiter = hierarchyDelimiter
        }
        
        /// Whether this mailbox can be selected
        public var isSelectable: Bool {
            return !attributes.contains(.noSelect)
        }
        
        /// Whether this mailbox has child mailboxes
        public var hasChildren: Bool {
            return attributes.contains(.hasChildren)
        }
        
        /// Whether this mailbox has no child mailboxes
        public var hasNoChildren: Bool {
            return attributes.contains(.hasNoChildren)
        }
        
        /// Whether this mailbox is marked
        public var isMarked: Bool {
            return attributes.contains(.marked)
        }
        
        /// Whether this mailbox is unmarked
        public var isUnmarked: Bool {
            return attributes.contains(.unmarked)
        }
    }
    
    /// Status information about a mailbox from a SELECT command
    public struct Status: Sendable {
        /// The total number of messages in the mailbox
        public var messageCount: Int = 0
        
        /// The number of recent messages in the mailbox
        public var recentCount: Int = 0
        
        /// The number of unseen messages in the mailbox
        public var unseenCount: Int = 0
        
        /// The sequence number of the first unseen message
        public var firstUnseen: Int = 0
        
        /// The UID validity value for the mailbox
        public var uidValidity: UInt32 = 0
        
        /// The next UID value for the mailbox
        public var uidNext: UID = UID(0)
        
        /// Whether the mailbox is read-only
        public var isReadOnly: Bool = false
        
        /// The flags available in the mailbox
        public var availableFlags: [Flag] = []
        
        /// The flags that can be permanently stored
        public var permanentFlags: [Flag] = []
        
        /// Initialize a new mailbox status
        public init() {}
    }
    
    /// The name of the mailbox
    public let name: String
    
    /// Basic information about the mailbox (from LIST command)
    public let info: Info
    
    /// Current status of the mailbox (from SELECT command), if selected
    public var status: Status?
    
    /// Initialize with just LIST information
    public init(info: Info) {
        self.name = info.name
        self.info = info
        self.status = nil
    }
    
    /// Whether this mailbox is currently selected
    public var isSelected: Bool {
        return status != nil
    }
}

// MARK: - CustomStringConvertible
extension Mailbox: CustomStringConvertible {
    public var description: String {
        var desc = "Mailbox(\(name)"
        
        if !info.attributes.isEmpty {
            desc += ", attributes: \(info.attributes)"
        }
        if let delimiter = info.hierarchyDelimiter {
            desc += ", delimiter: \(delimiter)"
        }
        if let status = status {
            desc += ", selected: messages=\(status.messageCount)"
            if status.unseenCount > 0 {
                desc += ", unseen=\(status.unseenCount)"
            }
        }
        
        desc += ")"
        return desc
    }
}

extension Mailbox.Info: CustomStringConvertible {
    public var description: String {
        var desc = "Info(\(name)"
        if !attributes.isEmpty {
            desc += ", attributes: \(attributes)"
        }
        if let delimiter = hierarchyDelimiter {
            desc += ", delimiter: \(delimiter)"
        }
        desc += ")"
        return desc
    }
}

extension Mailbox.Status: CustomStringConvertible {
    public var description: String {
        var desc = "Status("
        desc += "messages=\(messageCount)"
        if unseenCount > 0 {
            desc += ", unseen=\(unseenCount)"
        }
        if recentCount > 0 {
            desc += ", recent=\(recentCount)"
        }
        if isReadOnly {
            desc += ", readonly"
        }
        desc += ")"
        return desc
    }
} 
