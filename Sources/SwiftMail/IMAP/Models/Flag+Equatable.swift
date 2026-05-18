import Foundation

// MARK: - Equatable Implementation
extension Flag: Equatable {
    public static func == (lhs: Flag, rhs: Flag) -> Bool {
        switch (lhs, rhs) {
        case (.seen, .seen),
             (.answered, .answered),
             (.flagged, .flagged),
             (.deleted, .deleted),
             (.draft, .draft):
            return true
        case (.custom(let lhsValue), .custom(let rhsValue)):
            return lhsValue.caseInsensitiveCompare(rhsValue) == .orderedSame
        default:
            return false
        }
    }
}
