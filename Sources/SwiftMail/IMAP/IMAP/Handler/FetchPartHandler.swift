// FetchPartHandler.swift
// A specialized handler for IMAP fetch part operations

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP FETCH PART command
final class FetchPartHandler: BaseIMAPCommandHandler<Data>, IMAPCommandHandler, @unchecked Sendable {
    /// Collected message part data
    private var partData: Data = Data()

    private var parts: [MessagePart]?

    /// Expected byte count for the streaming data
    private var expectedByteCount: Int?

    /// Sequence number we are currently collecting for
    private var currentSequence: SequenceNumber?

    /// The message identifier we expect to receive
    var expectedSequence: SequenceNumber?
    var expectedUID: UID?

    /// Whether we're currently collecting data for the expected message
    private var isCollecting = false

    /// Sequence number of the last `.start` response
    private var pendingSequence: SequenceNumber?

    /// Whether we've already finished collecting our requested part
    private var didFinishPart = false
    
    	/// Handle a tagged OK response by succeeding the promise with the collected data
	/// - Parameter response: The tagged response
	override func handleTaggedOKResponse(_ response: TaggedResponse) {
		// Call super to handle CLIENTBUG warnings
		super.handleTaggedOKResponse(response)
		
		// Succeed with the collected data
		succeedWithResult(lock.withLock { self.partData })
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
    
    /// Process a fetch response
    /// - Parameter fetchResponse: The fetch response to process
    private func processFetchResponse(_ fetchResponse: FetchResponse) {
        switch fetchResponse {
        case .start(let seq):
            pendingSequence = SequenceNumber(seq.rawValue)

            // If we know the expected sequence number, start collecting immediately
            if let expectedSequence, expectedSequence == pendingSequence {
                currentSequence = expectedSequence
                isCollecting = true
                lock.withLock { self.partData.removeAll(keepingCapacity: true) }
            } else {
                isCollecting = false
            }

        case .simpleAttribute(let attribute):
            guard !didFinishPart else { return }

            // If we're expecting a specific UID, wait until we see it before collecting
            if let expectedUID, !isCollecting {
                if case .uid(let uid) = attribute, UID(nio: uid) == expectedUID {
                    currentSequence = pendingSequence
                    isCollecting = true
                    lock.withLock { self.partData.removeAll(keepingCapacity: true) }
                }
            }

            if isCollecting {
                processMessageAttribute(attribute)
            }

        case .streamingBegin(_, let byteCount):
            if isCollecting && !didFinishPart {
                expectedByteCount = byteCount
            }

        case .streamingBytes(let data):
            if isCollecting && !didFinishPart {
                lock.withLock {
                    self.partData.append(Data(data.readableBytesView))
                }
            }

        case .finish:
            if isCollecting && !didFinishPart {
                didFinishPart = true
                isCollecting = false
            }

        default:
            break
        }
    }
    
    /// Process a message attribute
    /// - Parameter attribute: The attribute to process
    private func processMessageAttribute(_ attribute: MessageAttribute) {
        switch attribute {
            case .body(let bodyStructure, _):
                if case .valid(let structure) = bodyStructure {
                    lock.withLock {
						self.parts = .init(structure)
                    }
                }
                
            default:
                break
        }
    }
} 
