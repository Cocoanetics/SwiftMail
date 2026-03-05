import Foundation
import NIOIMAPCore

/// Re-exports ``NIOIMAPCore/PartialRange`` so callers can construct paged search
/// windows without importing NIOIMAPCore directly.
public typealias PartialRange = NIOIMAPCore.PartialRange

/// The result of an IMAP ESEARCH command (RFC 4731).
///
/// Contains the structured data returned by the server, including optional
/// COUNT, MIN, MAX, ALL, and PARTIAL fields.  When ESEARCH is not available the
/// result is synthesised from a plain SEARCH response so that callers always
/// receive the same type.
public struct ExtendedSearchResult<T: MessageIdentifier>: Sendable {
    /// Total number of messages matching the search criteria, if requested.
    public let count: Int?

    /// The lowest message identifier matching the search criteria, if requested.
    public let min: T?

    /// The highest message identifier matching the search criteria, if requested.
    public let max: T?

    /// All message identifiers matching the search criteria, if requested.
    public let all: MessageIdentifierSet<T>?

    /// A paged subset of results returned when PARTIAL was requested.
    ///
    /// Non-nil only when the command was issued with a ``PartialRange`` and the
    /// server returned a PARTIAL datum.  When PARTIAL is used the `all` field is
    /// `nil` because the two return options are mutually exclusive.
    public let partial: PartialResult?

    /// The paged result for a PARTIAL ESEARCH request.
    public struct PartialResult: Sendable {
        /// The window that was requested (matches the range sent in the command).
        public let range: PartialRange
        /// Message identifiers within the window that satisfy the search criteria.
        public let results: MessageIdentifierSet<T>
    }

    /// Creates an ``ExtendedSearchResult`` from its components.
    public init(
        count: Int? = nil,
        min: T? = nil,
        max: T? = nil,
        all: MessageIdentifierSet<T>? = nil,
        partial: PartialResult? = nil
    ) {
        self.count = count
        self.min = min
        self.max = max
        self.all = all
        self.partial = partial
    }
}
