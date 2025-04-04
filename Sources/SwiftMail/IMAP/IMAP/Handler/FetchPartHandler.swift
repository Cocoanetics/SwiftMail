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
    
    /// Handle a tagged OK response by succeeding the promise with the collected data
    /// - Parameter response: The tagged response
    override func handleTaggedOKResponse(_ response: TaggedResponse) {
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
            case .simpleAttribute(let attribute):
                // Process simple attributes
                processMessageAttribute(attribute)
                
            case .streamingBegin(_, let byteCount):
                // Store the expected byte count
                expectedByteCount = byteCount
                
            case .streamingBytes(let data):
                // Collect the streaming body data
                lock.withLock {
                    self.partData.append(Data(data.readableBytesView))
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
