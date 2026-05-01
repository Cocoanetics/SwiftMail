/// Stable SwiftMail-owned representation of IMAP SORT criteria.
///
/// SwiftMail previously re-exported `NIOIMAPCore.SortCriterion`, but that type
/// is currently only available on unreleased `swift-nio-imap` revisions.
/// Keeping the model local lets SwiftMail stay semver-consumable while still
/// issuing standards-compliant `SORT` / `UID SORT` commands.
public enum SortCriterion: Hashable, Sendable {
    case ascending(Key)
    case descending(Key)

    public enum Key: String, Hashable, Sendable, CaseIterable {
        case arrival = "ARRIVAL"
        case cc = "CC"
        case date = "DATE"
        case from = "FROM"
        case size = "SIZE"
        case subject = "SUBJECT"
        case to = "TO"
        case displayFrom = "DISPLAYFROM"
        case displayTo = "DISPLAYTO"
    }
}

extension SortCriterion {
    var requiresDisplaySortCapability: Bool {
        switch self {
        case .ascending(.displayFrom), .ascending(.displayTo),
             .descending(.displayFrom), .descending(.displayTo):
            return true
        default:
            return false
        }
    }

    var imapWireRepresentation: String {
        switch self {
        case .ascending(let key):
            return key.rawValue
        case .descending(let key):
            return "REVERSE \(key.rawValue)"
        }
    }
}
