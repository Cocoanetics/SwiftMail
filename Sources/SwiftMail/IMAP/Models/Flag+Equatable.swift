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
                true
            case let (.custom(lhsValue), .custom(rhsValue)):
                lhsValue.caseInsensitiveCompare(rhsValue) == .orderedSame
            default:
                false
        }
    }
}
