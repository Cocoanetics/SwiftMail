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
    case older(seconds: Int)

    /** Matches messages younger than the specified number of seconds (RFC 5032 WITHIN extension).
     *  The interval must be a positive integer (≥ 1). Requires the server to advertise the `WITHIN` capability.
     */
    case younger(seconds: Int)

    /** Validates this search criteria, throwing if any values are out of range. */
    func validate() throws {
        switch self {
        case .older(let seconds), .younger(let seconds):
            guard seconds > 0 else {
                throw IMAPError.invalidArgument("WITHIN interval must be a positive integer (got \(seconds))")
            }
        case .and(let criterias):
            for child in criterias { try child.validate() }
        case .not(let criteria):
            try criteria.validate()
        case .or(let left, let right):
            try left.validate()
            try right.validate()
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
        case .or(let left, let right):
            return left.requiresWithin || right.requiresWithin
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
        if let key = logicalKey(calendar: calendar) { return key }
        if let key = positiveFlagKey() { return key }
        if let key = negativeFlagKey() { return key }
        if let key = dateKey(calendar: calendar) { return key }
        if let key = textKey() { return key }
        if let key = sizeAndIdentifierKey() { return key }
        return miscellaneousKey(calendar: calendar)
    }

    /// Logical combinators and the top-level `.all` constant.
    private func logicalKey(calendar: Calendar) -> NIOIMAP.SearchKey? {
        switch self {
        case .all:
            return .all
        case .and(let criterias):
            return .and(criterias.map { $0.toNIO(calendar: calendar) })
        case .not(let criteria):
            return .not(criteria.toNIO(calendar: calendar))
        case .or(let lhs, let rhs):
            return .or(lhs.toNIO(calendar: calendar), rhs.toNIO(calendar: calendar))
        default:
            return nil
        }
    }

    /// Positive flag-related criteria (answered/deleted/draft/flagged/seen/recent/new/old + keyword).
    private func positiveFlagKey() -> NIOIMAP.SearchKey? {
        switch self {
        case .answered: return .answered
        case .deleted: return .deleted
        case .draft: return .draft
        case .flagged: return .flagged
        case .new: return .new
        case .old: return .old
        case .recent: return .recent
        case .seen: return .seen
        case .keyword(let value): return .keyword(stringToKeyword(value))
        default: return nil
        }
    }

    /// Negative flag-related criteria (unanswered/undeleted/undraft/unflagged/unseen + unkeyword).
    private func negativeFlagKey() -> NIOIMAP.SearchKey? {
        switch self {
        case .unanswered: return .unanswered
        case .undeleted: return .undeleted
        case .undraft: return .undraft
        case .unflagged: return .unflagged
        case .unseen: return .unseen
        case .unkeyword(let value): return .unkeyword(stringToKeyword(value))
        default: return nil
        }
    }

    /// Date-related criteria — both internal-date and Date: header variants.
    private func dateKey(calendar: Calendar) -> NIOIMAP.SearchKey? {
        switch self {
        case .before(let date): return .before(dateToCalendarDay(date, calendar: calendar))
        case .on(let date): return .on(dateToCalendarDay(date, calendar: calendar))
        case .since(let date): return .since(dateToCalendarDay(date, calendar: calendar))
        case .sentBefore(let date): return .sentBefore(dateToCalendarDay(date, calendar: calendar))
        case .sentOn(let date): return .sentOn(dateToCalendarDay(date, calendar: calendar))
        case .sentSince(let date): return .sentSince(dateToCalendarDay(date, calendar: calendar))
        default: return nil
        }
    }

    /// Text-search criteria (header/body/text fields).
    private func textKey() -> NIOIMAP.SearchKey? {
        switch self {
        case .bcc(let value): return .bcc(stringToBuffer(value))
        case .body(let value): return .body(stringToBuffer(value))
        case .cc(let value): return .cc(stringToBuffer(value))
        case .from(let value): return .from(stringToBuffer(value))
        case .header(let field, let value): return .header(field, stringToBuffer(value))
        case .subject(let value): return .subject(stringToBuffer(value))
        case .text(let value): return .text(stringToBuffer(value))
        case .to(let value): return .to(stringToBuffer(value))
        default: return nil
        }
    }

    /// Message size and identifier criteria (larger/smaller/UID).
    private func sizeAndIdentifierKey() -> NIOIMAP.SearchKey? {
        switch self {
        case .larger(let size): return .messageSizeLarger(size)
        case .smaller(let size): return .messageSizeSmaller(size)
        case .uid(let value):
            let uid = NIOIMAPCore.UID(rawValue: UInt32(value))
            let range = NIOIMAPCore.MessageIdentifierRange<NIOIMAPCore.UID>(uid)
            let set = NIOIMAPCore.MessageIdentifierSetNonEmpty<NIOIMAPCore.UID>(range: range)
            return .uid(.set(set))
        default: return nil
        }
    }

    /// Remaining criteria: mod-sequence and WITHIN extension (older/younger).
    /// Called last after every other helper returned `nil`, so this is total over the remaining cases.
    private func miscellaneousKey(calendar: Calendar) -> NIOIMAP.SearchKey {
        switch self {
        case .modSeq(let searchModificationSequence):
            return .modificationSequence(searchModificationSequence)
        case .older(let seconds):
            return .older(seconds)
        case .younger(let seconds):
            return .younger(seconds)
        default:
            // Unreachable: every other case is handled by the helpers above.
            preconditionFailure("Unhandled SearchCriteria case in toNIO: \(self)")
        }
    }
}
