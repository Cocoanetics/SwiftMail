import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP NAMESPACE command
final class NamespaceHandler: BaseIMAPCommandHandler<NamespaceResponse>, IMAPCommandHandler, @unchecked Sendable {
    private var namespace: NamespaceResponse?

    	override func handleTaggedOKResponse(_ response: TaggedResponse) {
		// Call super to handle CLIENTBUG warnings
		super.handleTaggedOKResponse(response)

		if let namespace = lock.withLock({ self.namespace }) {
			succeedWithResult(namespace)
		} else {
			failWithError(IMAPError.commandFailed("NAMESPACE response missing"))
		}
	}

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.commandFailed(String(describing: response.state)))
    }

    override func handleUntaggedResponse(_ response: Response) -> Bool {
        if case .untagged(let payload) = response {
            if case .mailboxData(.namespace(let payload)) = payload {
                lock.withLock { self.namespace = NamespaceResponse(from: payload) }
            }
        }
        return false
    }
}
