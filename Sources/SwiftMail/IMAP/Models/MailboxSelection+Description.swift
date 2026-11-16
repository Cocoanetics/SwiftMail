import Foundation

extension Mailbox.Selection: CustomStringConvertible {
    public var description: String {
        var desc = "Selection("

        desc += "messages=\(messageCount)"
        if firstUnseen > 0 {
            desc += ", firstUnseen=\(firstUnseen)"
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
