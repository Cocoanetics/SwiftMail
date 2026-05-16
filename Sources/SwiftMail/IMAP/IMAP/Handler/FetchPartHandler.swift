// FetchPartHandler.swift
// A specialized handler for IMAP fetch part operations

import Foundation
import NIO
import NIOConcurrencyHelpers
@preconcurrency import NIOIMAP
import NIOIMAPCore

/// Handler for IMAP FETCH PART command
final class FetchPartHandler: BaseIMAPCommandHandler<Data>, IMAPCommandHandler, @unchecked Sendable {
    /// Collected message part data
    private var partData: Data = .init()

    private var parts: [MessagePart]?

    /// Expected byte count for the streaming data
    private var expectedByteCount: Int?

    /// Sequence number we are currently collecting for
    private var currentSequence: SequenceNumber?

    /// Whether we've already finished collecting our requested part
    private var didFinishPart = false

    /// Handle a tagged OK response by succeeding the promise with the collected data
    /// - Parameter response: The tagged response
    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        // Call super to handle CLIENTBUG warnings
        super.handleTaggedOKResponse(response)

        // Succeed with the collected data
        let collectedPartData = lock.withLock { self.partData }
        succeedWithResult(collectedPartData)
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
        if case let .fetch(fetchResponse) = response {
            processFetchResponse(fetchResponse)
        }

        // Return the result from the base class
        return handled
    }

    /// Process a fetch response
    /// - Parameter fetchResponse: The fetch response to process
    private func processFetchResponse(_ fetchResponse: FetchResponse) {
        // Once we've finished collecting our requested part, ignore further responses.
        guard !didFinishPart else { return }

        switch fetchResponse {
            case let .start(seq):
                // Only record the first sequence number and reset the buffer
                currentSequence = SequenceNumber(seq.rawValue)
                lock.withLock { self.partData.removeAll(keepingCapacity: true) }

            case let .simpleAttribute(attribute):
                processMessageAttribute(attribute)

            case let .streamingBegin(_, byteCount):
                expectedByteCount = byteCount

            case let .streamingBytes(data):
                lock.withLock {
                    self.partData.append(Data(data.readableBytesView))
                }

            case .finish:
                // Mark that we've finished collecting the requested part
                didFinishPart = true

            default:
                break
        }
    }

    /// Process a message attribute
    /// - Parameter attribute: The attribute to process
    private func processMessageAttribute(_ attribute: MessageAttribute) {
        switch attribute {
            case let .body(bodyStructure, _):
                if case let .valid(structure) = bodyStructure {
                    lock.withLock {
                        self.parts = .init(structure)
                    }
                }

            default:
                break
        }
    }
}
