import Foundation
import NIOIMAPCore

/// Represents an IMAP mailbox namespace
public enum Mailbox {
    /// Information about a mailbox from a LIST command
    public struct Info: Sendable {
        /// Attributes of a mailbox from a LIST command
        public struct Attributes: OptionSet, Sendable {
            public let rawValue: UInt16
            
            public init(rawValue: UInt16) {
                self.rawValue = rawValue
            }
            
            /// The mailbox cannot be selected
            public static let noSelect = Attributes(rawValue: 1 << 0)
            
            /// The mailbox has child mailboxes
            public static let hasChildren = Attributes(rawValue: 1 << 1)
            
            /// The mailbox has no child mailboxes
            public static let hasNoChildren = Attributes(rawValue: 1 << 2)
            
            /// The mailbox is marked
            public static let marked = Attributes(rawValue: 1 << 3)
            
            /// The mailbox is unmarked
            public static let unmarked = Attributes(rawValue: 1 << 4)
            
            // MARK: - Special-Use Attributes (RFC 6154)
            
            /// The mailbox is used for archive storage
            public static let archive = Attributes(rawValue: 1 << 5)
            
            /// The mailbox is used to store draft messages
            public static let drafts = Attributes(rawValue: 1 << 6)
            
            /// The mailbox contains flagged/important messages
            public static let flagged = Attributes(rawValue: 1 << 7)
            
            /// The mailbox is used to store junk/spam messages
            public static let junk = Attributes(rawValue: 1 << 8)
            
            /// The mailbox is used to store sent messages
            public static let sent = Attributes(rawValue: 1 << 9)
            
            /// The mailbox is used to store deleted/trash messages
            public static let trash = Attributes(rawValue: 1 << 10)
            
            /// The mailbox is the primary inbox
            public static let inbox = Attributes(rawValue: 1 << 11)
            
            /// Initialize from NIOIMAPCore.MailboxInfo.Attribute array
            init(from attributes: [NIOIMAPCore.MailboxInfo.Attribute]) {
                var result: Attributes = []
                
                for attribute in attributes {
                    switch attribute {
                    case .noSelect:
                        result.insert(.noSelect)
                    case .hasChildren:
                        result.insert(.hasChildren)
                    case .hasNoChildren:
                        result.insert(.hasNoChildren)
                    case .marked:
                        result.insert(.marked)
                    case .unmarked:
                        result.insert(.unmarked)
                    default:
                        // Check for special-use attributes in the raw value
                        let rawString = String(describing: attribute)
                        if rawString.contains("\\Archive") {
                            result.insert(.archive)
                        } else if rawString.contains("\\Drafts") {
                            result.insert(.drafts)
                        } else if rawString.contains("\\Flagged") {
                            result.insert(.flagged)
                        } else if rawString.contains("\\Junk") {
                            result.insert(.junk)
                        } else if rawString.contains("\\Sent") {
                            result.insert(.sent)
                        } else if rawString.contains("\\Trash") {
                            result.insert(.trash)
                        } else if rawString.contains("\\Inbox") {
                            result.insert(.inbox)
                        }
                        // Ignore any other attributes for now
                    }
                }
                
                self = result
            }
        }
        
        /// The name of the mailbox
        public let name: String
        
        /// The attributes of the mailbox
        public let attributes: Attributes
        
        /// The hierarchy delimiter used by the server
        public let hierarchyDelimiter: Character?
        
        /// Initialize from NIOIMAPCore.MailboxInfo
        public init(from info: NIOIMAPCore.MailboxInfo) {
            self.name = String(decoding: info.path.name.bytes, as: UTF8.self)
            self.attributes = Attributes(from: Array(info.attributes))
            self.hierarchyDelimiter = info.path.pathSeparator
        }
        
        /// Initialize with raw values
        public init(name: String, attributes: Attributes, hierarchyDelimiter: Character?) {
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
        
        /// Get a sequence number set for the latest n messages in the mailbox
        /// - Parameter count: The number of latest messages to include
        /// - Returns: A sequence number set containing the latest n messages, or nil if the mailbox is empty
        public func latest(_ count: Int) -> SequenceNumberSet? {
            guard messageCount > 0 else { return nil }
            
            let startIndex = max(1, messageCount - count + 1)
            let endIndex = messageCount
            
            let startMessage = SequenceNumber(startIndex)
            let endMessage = SequenceNumber(endIndex)
            
            return SequenceNumberSet(startMessage...endMessage)
        }
    }
}

// MARK: - CustomStringConvertible
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

extension Mailbox.Info.Attributes: CustomStringConvertible {
    public var description: String {
        var components: [String] = []
        
        if contains(.noSelect) { components.append("noSelect") }
        if contains(.hasChildren) { components.append("hasChildren") }
        if contains(.hasNoChildren) { components.append("hasNoChildren") }
        if contains(.marked) { components.append("marked") }
        if contains(.unmarked) { components.append("unmarked") }
        
        // Add special-use attributes
        if contains(.archive) { components.append("\\Archive") }
        if contains(.drafts) { components.append("\\Drafts") }
        if contains(.flagged) { components.append("\\Flagged") }
        if contains(.junk) { components.append("\\Junk") }
        if contains(.sent) { components.append("\\Sent") }
        if contains(.trash) { components.append("\\Trash") }
        if contains(.inbox) { components.append("\\Inbox") }
        
        return components.isEmpty ? "[]" : "[\(components.joined(separator: ", "))]"
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

// MARK: - Special Folders Extension
extension Array where Element == Mailbox.Info {
    /// Find the first mailbox with the inbox attribute, defaulting to the standard "INBOX" if none found
    public var inbox: Element? {
        // First look for a mailbox with the inbox attribute
        if let inboxMailbox = first(where: { $0.attributes.contains(.inbox) }) {
            return inboxMailbox
        }
        
        // As a fallback, look for the standard INBOX mailbox
        return first(where: { $0.name.caseInsensitiveCompare("INBOX") == .orderedSame })
    }
    
    /// Find the first mailbox with the sent attribute
    public var sent: Element? {
        return first(where: { $0.attributes.contains(.sent) })
    }
    
    /// Find the first mailbox with the drafts attribute
    public var drafts: Element? {
        return first(where: { $0.attributes.contains(.drafts) })
    }
    
    /// Find the first mailbox with the trash attribute
    public var trash: Element? {
        return first(where: { $0.attributes.contains(.trash) })
    }
    
    /// Find the first mailbox with the junk attribute
    public var junk: Element? {
        return first(where: { $0.attributes.contains(.junk) })
    }
    
    /// Find the first mailbox with the archive attribute
    public var archive: Element? {
        return first(where: { $0.attributes.contains(.archive) })
    }
    
    /// Find the first mailbox with the flagged attribute
    public var flagged: Element? {
        return first(where: { $0.attributes.contains(.flagged) })
    }
    
    /// Get only mailboxes with special-use attributes
    public var specialFolders: [Element] {
        return filter { mailbox in
            mailbox.attributes.contains(.inbox) ||
            mailbox.attributes.contains(.sent) ||
            mailbox.attributes.contains(.drafts) ||
            mailbox.attributes.contains(.trash) ||
            mailbox.attributes.contains(.junk) ||
            mailbox.attributes.contains(.archive) ||
            mailbox.attributes.contains(.flagged)
        }
    }
} 
