import Foundation

/// The result of an IMAP ESEARCH command (RFC 4731).
///
/// Contains the structured data returned by the server, including optional
/// COUNT, MIN, MAX, and ALL fields.  When ESEARCH is not available the result
/// is synthesised from a plain SEARCH response so that callers always receive
/// the same type.
public struct ExtendedSearchResult<T: MessageIdentifier>: Sendable {
    /// Total number of messages matching the search criteria, if requested.
    public let count: Int?

    /// The lowest message identifier matching the search criteria, if requested.
    public let min: T?

    /// The highest message identifier matching the search criteria, if requested.
    public let max: T?

    /// All message identifiers matching the search criteria, if requested.
    public let all: MessageIdentifierSet<T>?

    /// Creates an ``ExtendedSearchResult`` from its components.
    public init(
        count: Int? = nil,
        min: T? = nil,
        max: T? = nil,
        all: MessageIdentifierSet<T>? = nil
    ) {
        self.count = count
        self.min = min
        self.max = max
        self.all = all
    }
}
