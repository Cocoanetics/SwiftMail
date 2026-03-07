import Foundation
import NIOIMAP
import NIO
import NIOIMAPCore

/** A type that represents IMAP search criteria for filtering messages in a mailbox.

Use `SearchCriteria` to build search queries for finding messages that match specific conditions.
You can combine multiple criteria using logical operators like `.or` and `.not`.
*/
public indirect enum SearchCriteria: Sendable {
    /** Matches all messages in the mailbox. */
    case all
    
    /** Matches messages that match all specified search criterias. */
    case and([SearchCriteria])
    
    /** Matches messages with the `\Answered` flag set. */
    case answered
    
    /** Matches messages that contain the specified string in the BCC field. */
    case bcc(String)
    
    /** Matches messages with an internal date before the specified date. */
    case before(Date)
    
    /** Matches messages that contain the specified string in the message body. */
    case body(String)
    
    /** Matches messages that contain the specified string in the CC field. */
    case cc(String)
    
    /** Matches messages with the `\Deleted` flag set. */
    case deleted
    
    /** Matches messages with the `\Draft` flag set. */
    case draft
    
    /** Matches messages with the `\Flagged` flag set. */
    case flagged
    
    /** Matches messages that contain the specified string in the FROM field. */
    case from(String)
    
    /** Matches messages that contain the specified string in the specified header field. */
    case header(String, String)
    
    /** Matches messages with the specified keyword flag set. */
    case keyword(String)
    
    /** Matches messages larger than the specified size in bytes. */
    case larger(Int)
    
    /** Matches messages whose metadata changed after a given mod-sequence number.. */
    case modSeq(SearchModificationSequence)
    
    /** Matches messages that have the `\Recent` flag set but not the `\Seen` flag. */
    case new
    
    /** Matches messages that do not match the specified search criteria. */
    case not(SearchCriteria)
    
    /** Matches messages that do not have the `\Recent` flag set. */
    case old
    
    /** Matches messages whose internal date is within the specified date. */
    case on(Date)
    
    /** Matches messages that match either of the specified search criteria. */
    case or(SearchCriteria, SearchCriteria)
    
    /** Matches messages that have the `\Recent` flag set. */
    case recent
    
    /** Matches messages that have the `\Seen` flag set. */
    case seen
    
    /** Matches messages whose Date: header is before the specified date. */
    case sentBefore(Date)
    
    /** Matches messages whose Date: header is within the specified date. */
    case sentOn(Date)
    
    /** Matches messages whose Date: header is within or later than the specified date. */
    case sentSince(Date)
    
    /** Matches messages whose internal date is within or later than the specified date. */
    case since(Date)
    
    /** Matches messages smaller than the specified size in bytes. */
    case smaller(Int)
    
    /** Matches messages that contain the specified string in the Subject field. */
    case subject(String)
    
    /** Matches messages that contain the specified string in the message text (body and headers). */
    case text(String)
    
    /** Matches messages that contain the specified string in the TO field. */
    case to(String)
    
    /** Matches messages with the specified UID. */
    case uid(Int)
    
    /** Matches messages that do not have the `\Answered` flag set. */
    case unanswered
    
    /** Matches messages that do not have the `\Deleted` flag set. */
    case undeleted
    
    /** Matches messages that do not have the `\Draft` flag set. */
    case undraft
    
    /** Matches messages that do not have the `\Flagged` flag set. */
    case unflagged
    
    /** Matches messages that do not have the specified keyword flag set. */
    case unkeyword(String)
    
    /** Matches messages that do not have the `\Seen` flag set. */
    case unseen

    /** Matches messages older than the specified number of seconds (RFC 5032 WITHIN extension).
     *  The interval must be a positive integer (≥ 1). Requires the server to advertise the `WITHIN` capability.
     */
    case older(Int)

    /** Matches messages younger than the specified number of seconds (RFC 5032 WITHIN extension).
     *  The interval must be a positive integer (≥ 1). Requires the server to advertise the `WITHIN` capability.
     */
    case younger(Int)

    /** Validates this search criteria, throwing if any values are out of range. */
    func validate() throws {
        switch self {
        case .older(let seconds), .younger(let seconds):
            guard seconds > 0 else {
                throw IMAPError.invalidArgument("WITHIN interval must be a positive integer (got \(seconds))")
            }
        case .and(let criterias):
            for c in criterias { try c.validate() }
        case .not(let criteria):
            try criteria.validate()
        case .or(let c1, let c2):
            try c1.validate()
            try c2.validate()
        default:
            break
        }
    }

    /// Whether this criteria (or any nested child) requires the WITHIN extension.
    var requiresWithin: Bool {
        switch self {
        case .older, .younger:
            return true
        case .and(let criterias):
            return criterias.contains { $0.requiresWithin }
        case .not(let criteria):
            return criteria.requiresWithin
        case .or(let c1, let c2):
            return c1.requiresWithin || c2.requiresWithin
        default:
            return false
        }
    }

    /** Converts a Swift string to an NIO ByteBuffer.
     * - Parameter str: The string to convert.
     * - Returns: A ByteBuffer containing the string data.
     */
    private func stringToBuffer(_ str: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: str.utf8.count)
        buffer.writeString(str)
        return buffer
    }
    
    /** Converts a Swift Date to an IMAP calendar day.
     * - Parameters:
     *   - date: The date to convert.
     *   - calendar: The calendar used to extract date components. Defaults to the Gregorian calendar
     *     in the device's current timezone. Pass a UTC-configured calendar if you need deterministic
     *     date-only values regardless of the device's locale (recommended for IMAP SINCE/BEFORE
     *     queries whose date semantics are timezone-agnostic per RFC 3501).
     * - Returns: An IMAPCalendarDay representation of the date.
     */
    private func dateToCalendarDay(_ date: Date, calendar: Calendar) -> IMAPCalendarDay {
        let components = calendar.dateComponents([.day, .month, .year], from: date)
        
        // Create with correct parameter order (year, month, day)
        return IMAPCalendarDay(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1
        )!  // Force unwrap since we provide valid values
    }
    
    /** Converts a string to an IMAP keyword flag.
     * - Parameter str: The string to convert.
     * - Returns: A Flag.Keyword representation of the string.
     */
    private func stringToKeyword(_ str: String) -> NIOIMAPCore.Flag.Keyword {
        NIOIMAPCore.Flag.Keyword(str) ?? NIOIMAPCore.Flag.Keyword("CUSTOM")!
    }

    /** Converts the SwiftMail search criteria to the NIO IMAP search key format.
     * - Parameter calendar: The calendar used for date-to-day conversions. Defaults to the Gregorian
     *   calendar in the device's current timezone.
     * - Returns: The equivalent NIOIMAP.SearchKey for this search criteria.
     */
    func toNIO(calendar: Calendar = Calendar(identifier: .gregorian)) -> NIOIMAP.SearchKey {
        switch self {
        case .all:
            return .all
        case .and(let criterias):
            return .and(criterias.map { $0.toNIO(calendar: calendar) } )
        case .answered:
            return .answered
        case .bcc(let value):
            return .bcc(stringToBuffer(value))
        case .before(let date):
            return .before(dateToCalendarDay(date, calendar: calendar))
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
        case .header(let field, let value):
            return .header(field, stringToBuffer(value))
        case .keyword(let value):
            return .keyword(stringToKeyword(value))
        case .larger(let size):
            return .messageSizeLarger(size)
        case .modSeq(let searchModificationSequence):
            return .modificationSequence(searchModificationSequence)
        case .new:
            return .new
        case .not(let criteria):
            return .not(criteria.toNIO(calendar: calendar))
        case .old:
            return .old
        case .on(let date):
            return .on(dateToCalendarDay(date, calendar: calendar))
        case .or(let criteria1, let criteria2):
            return .or(criteria1.toNIO(calendar: calendar), criteria2.toNIO(calendar: calendar))
        case .recent:
            return .recent
        case .seen:
            return .seen
        case .sentBefore(let date):
            return .sentBefore(dateToCalendarDay(date, calendar: calendar))
        case .sentOn(let date):
            return .sentOn(dateToCalendarDay(date, calendar: calendar))
        case .sentSince(let date):
            return .sentSince(dateToCalendarDay(date, calendar: calendar))
        case .since(let date):
            return .since(dateToCalendarDay(date, calendar: calendar))
        case .smaller(let size):
            return .messageSizeSmaller(size)
        case .subject(let value):
            return .subject(stringToBuffer(value))
        case .text(let value):
            return .text(stringToBuffer(value))
        case .to(let value):
            return .to(stringToBuffer(value))
        case .uid(let value):
            let uid = NIOIMAPCore.UID(rawValue: UInt32(value))
            let range = NIOIMAPCore.MessageIdentifierRange<NIOIMAPCore.UID>(uid)
            let set = NIOIMAPCore.MessageIdentifierSetNonEmpty<NIOIMAPCore.UID>(range: range)
            return .uid(.set(set))
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
        case .older(let seconds):
            return .older(seconds)
        case .younger(let seconds):
            return .younger(seconds)
        }
    }
}
