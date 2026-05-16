// FetchHeadersHandler.swift
// A specialized handler for IMAP fetch headers operations

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP FETCH HEADERS command
final class FetchMessageInfoHandler: BaseIMAPCommandHandler<[MessageInfo]>, IMAPCommandHandler, @unchecked Sendable {
    /// Collected email headers
    internal var messageInfos: [MessageInfo] = []
    internal var currentSequenceNumber: SequenceNumber?
    internal var currentHeaderLiteral = Data()
    internal var collectingThreadingHeaders = false

    /// Handle a tagged OK response by succeeding the promise with the mailbox info
    /// - Parameter response: The tagged response
    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        // Call super to handle CLIENTBUG warnings
        super.handleTaggedOKResponse(response)

        // Succeed with the collected headers
        let collectedInfos = lock.withLock { self.messageInfos }
        succeedWithResult(collectedInfos)
    }

    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.fetchFailed(String(describing: response.state)))
    }

    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override func processResponse(_ response: Response) -> Bool {
        // Call the base class implementation to buffer the response
        let handled = super.processResponse(response)

        // Process fetch responses
        if case .fetch(let fetchResponse) = response {
            processFetchResponse(fetchResponse)
        }

        // Return the result from the base class
        return handled
    }
}
