// SelectHandler.swift
// Handler for IMAP SELECT command

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP SELECT command
final class SelectHandler: BaseIMAPCommandHandler<Mailbox.Selection>, IMAPCommandHandler, @unchecked Sendable {
    /// The type of result this handler produces
    typealias ResultType = Mailbox.Selection

    private var accumulator = MailboxSelectionAccumulator()

    /// Initialize a new select handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the select completes
    override init(commandTag: String, promise: EventLoopPromise<Mailbox.Selection>) {
        super.init(commandTag: commandTag, promise: promise)
    }

    /// Handle a tagged OK response by succeeding the promise with the mailbox info
    /// - Parameter response: The tagged response
    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        // SELECT/EXAMINE communicate READ-WRITE or READ-ONLY in the tagged
        // completion response. Capture it before fulfilling the result.
        if case .ok(let responseText) = response.state, let code = responseText.code {
            lock.withLock { accumulator.apply(code) }
        }

        // Call super to handle CLIENTBUG warnings
        super.handleTaggedOKResponse(response)

        // Succeed with the mailbox info
        succeedWithResult(lock.withLock { accumulator.selection })
    }

    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.selectFailed(String(describing: response.state)))
    }

    /// Handle untagged responses to extract mailbox information.
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override func handleUntaggedResponse(_ response: Response) -> Bool {
        guard case .untagged(let untaggedResponse) = response else { return false }
        switch untaggedResponse {
            case .conditionalState(.ok(let responseText)):
                if let code = responseText.code {
                    lock.withLock { accumulator.apply(code) }
                }
            case .mailboxData(let mailboxData):
                lock.withLock { accumulator.apply(mailboxData) }
            default:
                break
        }
        return false
    }

}
