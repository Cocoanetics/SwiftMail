import Foundation
import Logging
import NIO
import NIOIMAPCore

/** Handler for the CREATE command */
final class CreateMailboxHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {
    typealias ResultType = Void
    typealias InboundIn = Response
    typealias InboundOut = Never

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.createFailed(String(describing: response.state)))
    }
}
