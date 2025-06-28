import Foundation
import NIOIMAP
import NIOIMAPCore

/// Simplified message attribute representation for unsolicited FETCH responses.
public enum IMAPMessageAttribute: Sendable {
    /// List of flags currently set on the message.
    case flags([String])
    /// Modification sequence value of the message.
    case modseq(UInt64)
    /// The UID of the message.
    case uid(UInt32)
    // ... Add others as needed
}

extension IMAPMessageAttribute {
    /// Convert from `NIOIMAPCore.MessageAttribute` when possible.
    static func from(_ attribute: MessageAttribute) -> IMAPMessageAttribute? {
        switch attribute {
        case .flags(let flags):
            return .flags(flags.map { String($0) })
        case .fetchModificationResponse(let resp):
            return .modseq(resp.modificationSequenceValue.value)
        case .uid(let uid):
            return .uid(UInt32(uid.rawValue))
        default:
            return nil
        }
    }
}
