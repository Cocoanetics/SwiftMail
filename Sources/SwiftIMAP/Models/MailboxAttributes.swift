import Foundation
import NIOIMAPCore

/// Attributes of a mailbox from a LIST command
public struct MailboxAttributes: OptionSet, Sendable {
    public let rawValue: UInt16
    
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }
    
    /// The mailbox cannot be selected
    public static let noSelect = MailboxAttributes(rawValue: 1 << 0)
    
    /// The mailbox has child mailboxes
    public static let hasChildren = MailboxAttributes(rawValue: 1 << 1)
    
    /// The mailbox has no child mailboxes
    public static let hasNoChildren = MailboxAttributes(rawValue: 1 << 2)
    
    /// The mailbox is marked
    public static let marked = MailboxAttributes(rawValue: 1 << 3)
    
    /// The mailbox is unmarked
    public static let unmarked = MailboxAttributes(rawValue: 1 << 4)
    
    /// Initialize from NIOIMAPCore.MailboxInfo.Attribute array
    init(from attributes: [NIOIMAPCore.MailboxInfo.Attribute]) {
        var result: MailboxAttributes = []
        
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

extension MailboxAttributes: CustomStringConvertible {
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