import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

/// Command that issues an ESEARCH-style search when the server advertises the
/// ESEARCH capability (RFC 4731), and gracefully falls back to a plain SEARCH
/// otherwise.
///
/// The generic parameter ``T`` selects sequence numbers vs. UIDs, mirroring
/// ``SearchCommand``.
struct ExtendedSearchCommand<T: MessageIdentifier>: IMAPTaggedCommand, Sendable {
    typealias ResultType = ExtendedSearchResult<T>
    typealias HandlerType = ExtendedSearchHandler<T>

    /// Optional set of messages to limit the search scope.
    let identifierSet: MessageIdentifierSet<T>?
    /// Criteria that all messages must satisfy.
    let criteria: [SearchCriteria]
    /// Optional server-side sort criteria.
    let sortCriteria: [SortCriterion]
    /// Charset used when emitting `SORT`.
    let sortCharset: String
    /// Calendar used for date-to-day conversions.
    let calendar: Calendar
    /// Whether to issue SORT/UID SORT instead of SEARCH/UID SEARCH.
    let useSort: Bool
    /// Whether the server supports ESEARCH (determines which command is sent).
    let useEsearch: Bool
    /// Optional window for paged (PARTIAL) results. Only used when `useEsearch` is true.
    /// When non-nil, `PARTIAL` is requested instead of `ALL`.
    let partialRange: NIOIMAPCore.PartialRange?

    var timeoutSeconds: Int { return 60 }

    init(
        identifierSet: MessageIdentifierSet<T>? = nil,
        criteria: [SearchCriteria],
        sortCriteria: [SortCriterion] = [],
        sortCharset: String = "UTF-8",
        calendar: Calendar = Calendar(identifier: .gregorian),
        useSort: Bool = false,
        useEsearch: Bool,
        partialRange: NIOIMAPCore.PartialRange? = nil
    ) {
        self.identifierSet = identifierSet
        self.criteria = criteria
        self.sortCriteria = sortCriteria
        self.sortCharset = sortCharset
        self.calendar = calendar
        self.useSort = useSort
        self.useEsearch = useEsearch
        self.partialRange = partialRange
    }

    func validate() throws {
        guard !criteria.isEmpty else {
            throw IMAPError.invalidArgument("Search criteria cannot be empty")
        }
        guard !useSort || !sortCriteria.isEmpty else {
            throw IMAPError.invalidArgument("Sort criteria cannot be empty when SORT is enabled")
        }
        for criterion in criteria { try criterion.validate() }
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        var nioCriteria = criteria.map { $0.toNIO(calendar: calendar) }

        // Prepend identifier set scope as a search key so the search is
        // limited to the caller-provided message set (RFC 3501 §6.4.4).
        if let identifierSet {
            let scopeKey: SearchKey = T.self == UID.self
                ? .uid(.set(identifierSet.toNIOSet()))
                : .sequenceNumbers(.set(identifierSet.toNIOSet()))
            nioCriteria.insert(scopeKey, at: 0)
        }

        let key = SearchKey.and(nioCriteria)

        let returnOptions: [SearchReturnOption]
        if useEsearch {
            if let range = partialRange {
                // PARTIAL and ALL are mutually exclusive; use PARTIAL for paged results.
                returnOptions = [.count, .min, .max, .partial(range)]
            } else {
                returnOptions = [.count, .min, .max, .all]
            }
        } else {
            returnOptions = []
        }

        if useSort {
            if T.self == UID.self {
                return TaggedCommand(tag: tag, command: .uidSort(criteria: sortCriteria, charset: sortCharset, key: key, returnOptions: returnOptions))
            } else {
                return TaggedCommand(tag: tag, command: .sort(criteria: sortCriteria, charset: sortCharset, key: key, returnOptions: returnOptions))
            }
        } else if T.self == UID.self {
            return TaggedCommand(tag: tag, command: .uidSearch(key: key, returnOptions: returnOptions))
        } else {
            return TaggedCommand(tag: tag, command: .search(key: key, returnOptions: returnOptions))
        }
    }
}
