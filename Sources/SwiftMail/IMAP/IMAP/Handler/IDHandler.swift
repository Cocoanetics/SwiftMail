import Foundation
import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers
import OrderedCollections

/// Handler for the IMAP ID command.
final class IDHandler: BaseIMAPCommandHandler<Identification>, IMAPCommandHandler, @unchecked Sendable {
    private var responseParams: OrderedDictionary<String, String?> = [:]

    override func handleUntaggedResponse(_ response: Response) -> Bool {
        if case .untagged(let payload) = response, case .id(let params) = payload {
            lock.withLock { self.responseParams = params }
            return false
        }
        return super.handleUntaggedResponse(response)
    }

    	override func handleTaggedOKResponse(_ response: TaggedResponse) {
		// Call super to handle CLIENTBUG warnings
		super.handleTaggedOKResponse(response)
		
		let params = lock.withLock { responseParams }
		succeedWithResult(Identification(parameters: params))
	}

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.commandFailed(String(describing: response.state)))
    }
}
