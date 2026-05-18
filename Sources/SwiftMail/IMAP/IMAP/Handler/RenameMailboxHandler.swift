import Foundation
import Logging
import NIO
import NIOIMAPCore

/** Handler for the RENAME command. */
final class RenameMailboxHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {
    typealias ResultType = Void
    typealias InboundIn = Response
    typealias InboundOut = Never

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.renameFailed(String(describing: response.state)))
    }
}
