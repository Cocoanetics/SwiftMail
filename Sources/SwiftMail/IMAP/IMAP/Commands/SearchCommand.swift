import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

/**
 Command for searching the selected mailbox.

 The generic parameter ``T`` determines whether the search operates on
 sequence numbers or UIDs. The command returns a set of identifiers matching
 all supplied criteria.
 */
struct SearchCommand<T: MessageIdentifier>: IMAPTaggedCommand, Sendable {
    /// The type returned by the command handler.
    typealias ResultType = MessageIdentifierSet<T>
    /// The handler used to process the command's responses.
    typealias HandlerType = SearchHandler<T>

    /// Optional set of messages to limit the search scope.
    let identifierSet: MessageIdentifierSet<T>?
    /// Criteria that all messages must satisfy.
    let criteria: [SearchCriteria]
    /// Calendar used for date-to-day conversions in search criteria.
    let calendar: Calendar

    /// Timeout in seconds for the search operation.
    var timeoutSeconds: Int { return 60 }

    /**
     Create a new search command.
     - Parameters:
       - identifierSet: Optional set limiting the messages to search.
       - criteria: The search criteria to apply.
       - calendar: The calendar used for date-to-day conversions. Defaults to the Gregorian calendar.
     */
    init(identifierSet: MessageIdentifierSet<T>? = nil, criteria: [SearchCriteria], calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.identifierSet = identifierSet
        self.criteria = criteria
        self.calendar = calendar
    }

    /// Validate that the command has at least one criterion.
    func validate() throws {
        guard !criteria.isEmpty else {
            throw IMAPError.invalidArgument("Search criteria cannot be empty")
        }
        for criterion in criteria { try criterion.validate() }
    }

    /**
     Convert the command to its IMAP representation.
     - Parameter tag: The command tag used by the server.
     - Returns: A ``TaggedCommand`` ready for sending.
     */
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

        if T.self == UID.self {
            return TaggedCommand(tag: tag, command: .uidSearch(key: .and(nioCriteria)))
        } else {
            return TaggedCommand(tag: tag, command: .search(key: .and(nioCriteria)))
        }
    }
}
