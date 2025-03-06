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
                        // Ignore any other attributes for now
                        break
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
