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
    /// Calendar used for date-to-day conversions.
    let calendar: Calendar
    /// Whether the server supports ESEARCH (determines which command is sent).
    let useEsearch: Bool

    var timeoutSeconds: Int { return 60 }

    init(
        identifierSet: MessageIdentifierSet<T>? = nil,
        criteria: [SearchCriteria],
        calendar: Calendar = Calendar(identifier: .gregorian),
        useEsearch: Bool
    ) {
        self.identifierSet = identifierSet
        self.criteria = criteria
        self.calendar = calendar
        self.useEsearch = useEsearch
    }

    func validate() throws {
        guard !criteria.isEmpty else {
            throw IMAPError.invalidArgument("Search criteria cannot be empty")
        }
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

        let returnOptions: [SearchReturnOption] = useEsearch
            ? [.count, .min, .max, .all]
            : []

        if T.self == UID.self {
            return TaggedCommand(tag: tag, command: .uidSearch(key: key, returnOptions: returnOptions))
        } else {
            return TaggedCommand(tag: tag, command: .search(key: key, returnOptions: returnOptions))
        }
    }
}
