import Foundation
import NIO
@preconcurrency import NIOIMAP
import NIOIMAPCore

/// Handler for GETQUOTA command responses
final class QuotaHandler: BaseIMAPCommandHandler<Quota>, IMAPCommandHandler, @unchecked Sendable {
    private var quota: Quota?

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        // Call super to handle CLIENTBUG warnings
        super.handleTaggedOKResponse(response)

        if let quota {
            succeedWithResult(quota)
        } else {
            failWithError(IMAPError.commandFailed("QUOTA response missing"))
        }
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.commandFailed(String(describing: response.state)))
    }

    override func handleUntaggedResponse(_ response: Response) -> Bool {
        if case let .untagged(payload) = response, case let .quota(root, resources) = payload {
            quota = Quota(root: root, resources: resources)
            return false
        }
        return false
    }
}
