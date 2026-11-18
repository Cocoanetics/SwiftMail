import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

/**
 Handler for IMAP SEARCH commands.

 This handler processes search responses from the IMAP server and collects
 the message identifiers that match the search criteria.

 The generic parameter T specifies the exact MessageIdentifier type to be collected.
 */
final class SearchHandler<T: MessageIdentifier>:
    BaseIMAPCommandHandler<MessageIdentifierSet<T>>,
    IMAPCommandHandler,
    @unchecked Sendable {
    typealias ResultType = MessageIdentifierSet<T>
    typealias InboundIn = Response
    typealias InboundOut = Never

    private var searchResults: [T] = []
    /// Matches from an ESEARCH ALL, kept as ranges: a compact answer such as `1:100000` is never
    /// expanded into single identifiers.
    private var esearchMatches = MessageIdentifierSet<T>()
    /// Whether an untagged `SEARCH`, `SORT` or `ESEARCH` answer arrived. A search that matches
    /// nothing is still answered: `* SEARCH` with no numbers (RFC 3501 §6.4.4 and §7.2.5), or on
    /// IMAP4rev2 an ESEARCH without ALL (RFC 9051 §6.4.4). A tagged OK without one leaves the
    /// result unknown rather than empty.
    private var receivedAnswer = false
    /// Whether the command was a SORT; `nil` when the handler was built without its command.
    var expectsSort: Bool?
    /// Whether an ESEARCH showed matches (COUNT above zero, MIN or MAX) but left out the ALL a
    /// plain SEARCH asks for by default (RFC 9051 §6.4.4).
    private var matchedWithoutAll = false

    override func processResponse(_ response: Response) -> Bool {
        let handled = super.processResponse(response)

        // Check for untagged status responses that indicate errors
        if case let .untagged(untagged) = response,
           case let .conditionalState(status) = untagged {
            switch status {
                case .bad(let responseText):
                    // Handle BAD response (protocol error)
                    failWithError(
                        IMAPError.searchRejected(operation: "Search", status: "BAD", responseText: responseText)
                    )
                    return true
                case .no(let responseText):
                    // Handle NO response (operational error)
                    failWithError(
                        IMAPError.searchRejected(operation: "Search", status: "NO", responseText: responseText)
                    )
                    return true
                default:
                    // Other status responses are handled by the base class
                    break
            }
        }

        if case let .untagged(untagged) = response,
           case let .mailboxData(mailboxData) = untagged {
            ingest(mailboxData)
        }

        return handled
    }

    /// Record an untagged answer that belongs to this command.
    private func ingest(_ mailboxData: MailboxData) {
        switch mailboxData {
            case .search(let ids, _), .sort(let ids, _):
                guard acceptsLegacyAnswer(mailboxData, expectsSort: expectsSort) else { return }
                receivedAnswer = true
                searchResults.append(contentsOf: ids.map { T.init(UInt32($0)) })
            case .extendedSearch(let response):
                guard response.answers(commandTag: commandTag, identifiers: T.self) else { return }
                // This command never sends RETURN, so a SORT is answered only by `* SORT`
                // (RFC 5256 §3, RFC 5267 §3).
                guard expectsSort != true else { return }
                ingest(response)
            default:
                break
        }
    }

    /// An IMAP4rev2 server answers a plain SEARCH with ESEARCH, whose default return option is
    /// ALL (RFC 9051 §6.4.4): no ALL means nothing matched, unless COUNT, MIN or MAX say otherwise.
    private func ingest(_ response: ExtendedSearchResponse) {
        receivedAnswer = true
        var hasAll = false
        var showsMatches = false
        for datum in response.returnData {
            switch datum {
                case .all(.set(let nioSet)):
                    hasAll = true
                    esearchMatches.insert(unknownIdentifiers: nioSet.set)
                case .count(let count):
                    showsMatches = showsMatches || count > 0
                case .min, .max:
                    showsMatches = true
                default:
                    break
            }
        }
        matchedWithoutAll = showsMatches && !hasAll
    }

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        // Call super to handle CLIENTBUG warnings
        super.handleTaggedOKResponse(response)

        guard receivedAnswer else {
            failWithError(IMAPError.commandFailed(
                "Search completed with OK but no untagged SEARCH response (RFC 3501 §6.4.4)"
            ))
            return
        }
        guard !matchedWithoutAll else {
            failWithError(IMAPError.commandFailed(
                "Search failed: ESEARCH reported matches but omitted ALL (RFC 9051 §6.4.4)"
            ))
            return
        }

        // When we receive an OK response, the search is complete
        // Return the collected search results as a MessageIdentifierSet
        // Create a MessageIdentifierSet from the array of results
        var resultSet = esearchMatches
        for identifier in searchResults {
            resultSet.insert(identifier)
        }

        succeedWithResult(resultSet)
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        // If the search command fails, report the error with more specific information
        switch response.state {
            case .bad(let responseText):
                failWithError(
                    IMAPError.searchRejected(operation: "Search", status: "BAD", responseText: responseText)
                )
            case .no(let responseText):
                failWithError(
                    IMAPError.searchRejected(operation: "Search", status: "NO", responseText: responseText)
                )
            default:
                failWithError(IMAPError.commandFailed("Search failed: \(String(describing: response.state))"))
        }
    }
}
