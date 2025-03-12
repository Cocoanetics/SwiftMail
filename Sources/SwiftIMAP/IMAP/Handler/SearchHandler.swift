import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

/**
 * Handler for IMAP SEARCH and SORT commands.
 * 
 * This handler processes search and sort responses from the IMAP server and collects
 * the message identifiers that match the search or sort criteria.
 *
 * The generic parameter T specifies the exact MessageIdentifier type to be collected.
 */
public final class SearchHandler<T: MessageIdentifier>: BaseIMAPCommandHandler<MessageIdentifierSet<T>>, IMAPCommandHandler {
    public typealias ResultType = MessageIdentifierSet<T>
    public typealias InboundIn = Response
    public typealias InboundOut = Never
    
    private var searchResults: [T] = []
    
    override public func processResponse(_ response: Response) -> Bool {
        let handled = super.processResponse(response)
        
        // Check for untagged status responses that indicate errors
        if case let .untagged(untagged) = response,
           case let .conditionalState(status) = untagged {
            switch status {
            case .bad(let responseText):
                // Handle BAD response (protocol error)
                failWithError(IMAPError.commandFailed("Search/Sort failed: BAD \(responseText.text)"))
                return true
            case .no(let responseText):
                // Handle NO response (operational error)
                failWithError(IMAPError.commandFailed("Search/Sort failed: NO \(responseText.text)"))
                return true
            default:
                // Other status responses are handled by the base class
                break
            }
        }
        
		// Check for search or sort response data using proper pattern matching
		if case let .untagged(untagged) = response,
		   case let .mailboxData(mailboxData) = untagged,
		   case let .search(ids, _) = mailboxData {
			// Convert the IDs to the appropriate MessageIdentifier type
			let results = ids.map { T.init(UInt32($0)) }
			searchResults.append(contentsOf: results)
			print("Extracted \(results.count) message identifiers from search/sort response")
		}
        
        return handled
    }
    
    override public func handleTaggedOKResponse(_ response: TaggedResponse) {
        // When we receive an OK response, the search or sort is complete
        // Return the collected search or sort results as a MessageIdentifierSet
        print("Search/Sort complete, returning \(searchResults.count) results")
        
        // Create a MessageIdentifierSet from the array of results
        var resultSet = MessageIdentifierSet<T>()
        for identifier in searchResults {
            resultSet.insert(identifier)
        }
        
        succeedWithResult(resultSet)
    }
    
    override public func handleTaggedErrorResponse(_ response: TaggedResponse) {
        // If the search or sort command fails, report the error with more specific information
        switch response.state {
        case .bad(let responseText):
            failWithError(IMAPError.commandFailed("Search/Sort failed: BAD \(responseText.text)"))
        case .no(let responseText):
            failWithError(IMAPError.commandFailed("Search/Sort failed: NO \(responseText.text)"))
        default:
            failWithError(IMAPError.commandFailed("Search/Sort failed: \(String(describing: response.state))"))
        }
    }
}
