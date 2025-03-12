import Foundation
import NIOIMAPCore

public enum SortCriteria {
    case date
    case arrival
    case from
    case to
    case subject
    case size
    case reverse(SortCriteria)
    
    func toNIO() -> NIOIMAPCore.SortKey {
        switch self {
        case .date:
            return .date
        case .arrival:
            return .arrival
        case .from:
            return .from
        case .to:
            return .to
        case .subject:
            return .subject
        case .size:
            return .size
        case .reverse(let criteria):
            return .reverse(criteria.toNIO())
        }
    }
}
