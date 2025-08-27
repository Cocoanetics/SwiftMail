// ServerHandlers.swift
// Handlers for server-related IMAP commands

import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP CAPABILITY command
final class CapabilityHandler: BaseIMAPCommandHandler<[Capability]>, IMAPCommandHandler, @unchecked Sendable {
    /// Collected capabilities
    private var capabilities: [Capability] = []
    
    	/// Handle a tagged OK response by succeeding the promise with the capabilities
	/// - Parameter response: The tagged response
	override func handleTaggedOKResponse(_ response: TaggedResponse) {
		// Call super to handle CLIENTBUG warnings
		super.handleTaggedOKResponse(response)
		
		let caps = lock.withLock { self.capabilities }
		succeedWithResult(caps)
	}
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.commandFailed(String(describing: response.state)))
    }
    
    /// Handle an untagged response
    /// - Parameter response: The untagged response
    /// - Returns: Whether the response was handled by this handler
    override func handleUntaggedResponse(_ response: Response) -> Bool {
        if case .untagged(.capabilityData(let capabilities)) = response {
            lock.withLock {
                self.capabilities = capabilities
            }
            
            // We've processed the untagged response, but we're not done yet
            // Return false to indicate we haven't completed processing
            return false
        }
        
        // Not a capability response
        return false
    }
}

/// Handler for IMAP COPY command
final class CopyHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {
    
    /// Handle a tagged OK response by succeeding the promise
    /// - Parameter response: The tagged response
    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        // Call super to handle CLIENTBUG warnings
        super.handleTaggedOKResponse(response)
        
        succeedWithResult(())
    }
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.copyFailed(String(describing: response.state)))
    }
}

/// Handler for IMAP STORE command
final class StoreHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {

    /// Handle a tagged OK response by succeeding the promise
    /// - Parameter response: The tagged response
    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        // Call super to handle CLIENTBUG warnings
        super.handleTaggedOKResponse(response)
        
        succeedWithResult(())
    }
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.storeFailed(String(describing: response.state)))
    }
}

/// Handler for IMAP EXPUNGE command
final class ExpungeHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {

    /// Handle a tagged OK response by succeeding the promise
    /// - Parameter response: The tagged response
    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        // Call super to handle CLIENTBUG warnings
        super.handleTaggedOKResponse(response)
        
        succeedWithResult(())
    }
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.expungeFailed(String(describing: response.state)))
    }
} 
