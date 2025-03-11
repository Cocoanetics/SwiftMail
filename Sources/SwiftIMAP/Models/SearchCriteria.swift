import Foundation
import NIOIMAP

public enum SearchCriteria {
    case all
    case answered
    case bcc(String)
    case before(Date)
    case body(String)
    case cc(String)
    case deleted
    case draft
    case flagged
    case from(String)
    case header(String, String)
    case keyword(String)
    case larger(Int)
    case new
    case not(SearchCriteria)
    case old
    case on(Date)
    case or(SearchCriteria, SearchCriteria)
    case recent
    case seen
    case sentBefore(Date)
    case sentOn(Date)
    case sentSince(Date)
    case since(Date)
    case smaller(Int)
    case subject(String)
    case text(String)
    case to(String)
    case uid(Int)
    case unanswered
    case undeleted
    case undraft
    case unflagged
    case unkeyword(String)
    case unseen

    func toNIO() -> NIOIMAP.SearchKey {
        switch self {
        case .all:
            return .all
        case .answered:
            return .answered
        case .bcc(let value):
            return .bcc(value)
        case .before(let date):
            return .before(date)
        case .body(let value):
            return .body(value)
        case .cc(let value):
            return .cc(value)
        case .deleted:
            return .deleted
        case .draft:
            return .draft
        case .flagged:
            return .flagged
        case .from(let value):
            return .from(value)
        case .header(let field, let value):
            return .header(field, value)
        case .keyword(let value):
            return .keyword(value)
        case .larger(let size):
            return .larger(size)
        case .new:
            return .new
        case .not(let criteria):
            return .not(criteria.toNIO())
        case .old:
            return .old
        case .on(let date):
            return .on(date)
        case .or(let criteria1, let criteria2):
            return .or(criteria1.toNIO(), criteria2.toNIO())
        case .recent:
            return .recent
        case .seen:
            return .seen
        case .sentBefore(let date):
            return .sentBefore(date)
        case .sentOn(let date):
            return .sentOn(date)
        case .sentSince(let date):
            return .sentSince(date)
        case .since(let date):
            return .since(date)
        case .smaller(let size):
            return .smaller(size)
        case .subject(let value):
            return .subject(value)
        case .text(let value):
            return .text(value)
        case .to(let value):
            return .to(value)
        case .uid(let number):
            return .uid(number)
        case .unanswered:
            return .unanswered
        case .undeleted:
            return .undeleted
        case .undraft:
            return .undraft
        case .unflagged:
            return .unflagged
        case .unkeyword(let value):
            return .unkeyword(value)
        case .unseen:
            return .unseen
        }
    }
}
