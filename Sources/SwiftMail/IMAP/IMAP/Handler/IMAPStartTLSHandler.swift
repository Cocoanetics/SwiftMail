import Foundation
import NIO
@preconcurrency import NIOIMAP

/// Handler for IMAP STARTTLS command responses.
final class IMAPStartTLSHandler: BaseIMAPCommandHandler<Bool>, IMAPCommandHandler, @unchecked Sendable {
    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        super.handleTaggedOKResponse(response)
        succeedWithResult(true)
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.connectionFailed("STARTTLS failed: \(response.state)"))
    }
}
