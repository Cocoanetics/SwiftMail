// FetchStructureHandler.swift
// A specialized handler for IMAP fetch structure operations

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP FETCH STRUCTURE command
public final class FetchStructureHandler: BaseIMAPCommandHandler<BodyStructure>, IMAPCommandHandler {
    /// The body structure from the response
    private var bodyStructure: BodyStructure?
    
    /// Handle a tagged OK response by succeeding the promise with the body structure
    /// - Parameter response: The tagged response
    override public func handleTaggedOKResponse(_ response: TaggedResponse) {
        lock.withLock {
            if let structure = self.bodyStructure {
                succeedWithResult(structure)
            } else {
                failWithError(IMAPError.fetchFailed("No body structure received"))
            }
        }
    }
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override public func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.fetchFailed(String(describing: response.state)))
    }
    
    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override public func processResponse(_ response: Response) -> Bool {
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
                        self.bodyStructure = structure
                    }
                }
                
            default:
                break
        }
    }
} 
