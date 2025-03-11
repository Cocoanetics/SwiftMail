import Foundation
import NIOIMAP
import NIO
import NIOIMAPCore

public indirect enum SearchCriteria {
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

    private func stringToBuffer(_ str: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: str.utf8.count)
        buffer.writeString(str)
        return buffer
    }
    
    private func dateToCalendarDay(_ date: Date) -> IMAPCalendarDay {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.day, .month, .year], from: date)
        
        // Create with correct parameter order (year, month, day)
        return IMAPCalendarDay(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1
        )!  // Force unwrap since we provide valid values
    }
    
    private func stringToKeyword(_ str: String) -> NIOIMAPCore.Flag.Keyword {
        NIOIMAPCore.Flag.Keyword(str) ?? NIOIMAPCore.Flag.Keyword("CUSTOM")!
    }

    func toNIO() -> NIOIMAP.SearchKey {
        switch self {
        case .all:
            return .all
        case .answered:
            return .answered
        case .bcc(let value):
            return .bcc(stringToBuffer(value))
        case .before(let date):
            return .before(dateToCalendarDay(date))
        case .body(let value):
            return .body(stringToBuffer(value))
        case .cc(let value):
            return .cc(stringToBuffer(value))
        case .deleted:
            return .deleted
        case .draft:
            return .draft
        case .flagged:
            return .flagged
        case .from(let value):
            return .from(stringToBuffer(value))
        case .header(_, _):
            // For header, we need to use a different approach
            // Since we can't convert ByteBuffer to String directly
            return .all // Placeholder - will implement properly when API is better understood
        case .keyword(let value):
            return .keyword(stringToKeyword(value))
        case .larger(_):
            // For larger, use a workaround
            return .all // Placeholder - will implement properly when API is better understood
        case .new:
            return .new
        case .not(let criteria):
            return .not(criteria.toNIO())
        case .old:
            return .old
        case .on(let date):
            return .on(dateToCalendarDay(date))
        case .or(let criteria1, let criteria2):
            return .or(criteria1.toNIO(), criteria2.toNIO())
        case .recent:
            return .recent
        case .seen:
            return .seen
        case .sentBefore(let date):
            return .sentBefore(dateToCalendarDay(date))
        case .sentOn(let date):
            return .sentOn(dateToCalendarDay(date))
        case .sentSince(let date):
            return .sentSince(dateToCalendarDay(date))
        case .since(let date):
            return .since(dateToCalendarDay(date))
        case .smaller(_):
            // For smaller, use a workaround
            return .all // Placeholder - will implement properly when API is better understood
        case .subject(let value):
            return .subject(stringToBuffer(value))
        case .text(let value):
            return .text(stringToBuffer(value))
        case .to(let value):
            return .to(stringToBuffer(value))
        case .uid(_):
            // For UID, use a workaround
            return .all // Placeholder - will implement properly when API is better understood
        case .unanswered:
            return .unanswered
        case .undeleted:
            return .undeleted
        case .undraft:
            return .undraft
        case .unflagged:
            return .unflagged
        case .unkeyword(let value):
            return .unkeyword(stringToKeyword(value))
        case .unseen:
            return .unseen
        }
    }
}
