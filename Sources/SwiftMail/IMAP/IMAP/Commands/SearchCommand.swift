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
    
    /// Timeout in seconds for the search operation.
    var timeoutSeconds: Int { return 60 }

    /**
     Create a new search command.
     - Parameters:
       - identifierSet: Optional set limiting the messages to search.
       - criteria: The search criteria to apply.
     */
    init(identifierSet: MessageIdentifierSet<T>? = nil, criteria: [SearchCriteria]) {
        self.identifierSet = identifierSet
        self.criteria = criteria
    }

    /// Validate that the command has at least one criterion.
    func validate() throws {
        guard !criteria.isEmpty else {
            throw IMAPError.invalidArgument("Search criteria cannot be empty")
        }
    }

    /**
     Convert the command to its IMAP representation.
     - Parameter tag: The command tag used by the server.
     - Returns: A ``TaggedCommand`` ready for sending.
     */
    func toTaggedCommand(tag: String) -> TaggedCommand {
        let nioCriteria = criteria.map { $0.toNIO() }

        if T.self == UID.self {
            // For UID search, we need to use the key parameter
            return TaggedCommand(tag: tag, command: .uidSearch(key: .and(nioCriteria)))
        } else {
            // For regular search, we need to use the key parameter
            return TaggedCommand(tag: tag, command: .search(key: .and(nioCriteria)))
        }
    }
}
