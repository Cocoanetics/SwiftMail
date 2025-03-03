import Foundation
import NIOIMAPCore

/// Information about a mailbox from a LIST command
public struct MailboxInfo {
    /// The name of the mailbox
    public let name: String
    
    /// The attributes of the mailbox
    public let attributes: MailboxAttributes
    
    /// The hierarchy delimiter used by the server
    public let hierarchyDelimiter: Character?
    
    /// Initialize from NIOIMAPCore.MailboxInfo
    init(from info: NIOIMAPCore.MailboxInfo) {
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
}

extension MailboxInfo: CustomStringConvertible {
    public var description: String {
        var desc = "MailboxInfo(\(name)"
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

extension MailboxInfo {
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