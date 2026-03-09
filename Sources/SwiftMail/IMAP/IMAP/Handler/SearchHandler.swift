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
final class SearchHandler<T: MessageIdentifier>: BaseIMAPCommandHandler<MessageIdentifierSet<T>>, IMAPCommandHandler, @unchecked Sendable {
    typealias ResultType = MessageIdentifierSet<T>
    typealias InboundIn = Response
    typealias InboundOut = Never
    
    private var searchResults: [T] = []
    
    override func processResponse(_ response: Response) -> Bool {
        let handled = super.processResponse(response)
        
        // Check for untagged status responses that indicate errors
        if case let .untagged(untagged) = response,
           case let .conditionalState(status) = untagged {
            switch status {
            case .bad(let responseText):
                // Handle BAD response (protocol error)
                failWithError(IMAPError.commandFailed("Search failed: BAD \(responseText.text)"))
                return true
            case .no(let responseText):
                // Handle NO response (operational error)
                failWithError(IMAPError.commandFailed("Search failed: NO \(responseText.text)"))
                return true
            default:
                // Other status responses are handled by the base class
                break
            }
        }
        
		// Check for search response data using proper pattern matching
		if case let .untagged(untagged) = response,
		   case let .mailboxData(mailboxData) = untagged,
		   case let .search(ids, _) = mailboxData {
			// Convert the IDs to the appropriate MessageIdentifier type
			let results = ids.map { T.init(UInt32($0)) }
			searchResults.append(contentsOf: results)
		}
        
        return handled
    }
    
    	override func handleTaggedOKResponse(_ response: TaggedResponse) {
		// Call super to handle CLIENTBUG warnings
		super.handleTaggedOKResponse(response)
		
		// When we receive an OK response, the search is complete
		// Return the collected search results as a MessageIdentifierSet
		// Create a MessageIdentifierSet from the array of results
		var resultSet = MessageIdentifierSet<T>()
		for identifier in searchResults {
			resultSet.insert(identifier)
		}
		
		succeedWithResult(resultSet)
	}
    
    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        // If the search command fails, report the error with more specific information
        switch response.state {
        case .bad(let responseText):
            failWithError(IMAPError.commandFailed("Search failed: BAD \(responseText.text)"))
        case .no(let responseText):
            failWithError(IMAPError.commandFailed("Search failed: NO \(responseText.text)"))
        default:
            failWithError(IMAPError.commandFailed("Search failed: \(String(describing: response.state))"))
        }
    }
}
