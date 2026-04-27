import NIOIMAPCore

/// Re-exports ``NIOIMAPCore/SortCriterion`` so callers can request server-side
/// sorting without importing NIOIMAPCore directly.
public typealias SortCriterion = NIOIMAPCore.SortCriterion

extension NIOIMAPCore.SortCriterion {
    var requiresDisplaySortCapability: Bool {
        switch self {
        case .ascending(.displayFrom), .ascending(.displayTo),
             .descending(.displayFrom), .descending(.displayTo):
            return true
        default:
            return false
        }
    }
}
