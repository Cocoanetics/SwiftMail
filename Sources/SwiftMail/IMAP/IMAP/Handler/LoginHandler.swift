// LoginHandler.swift
// A specialized handler for IMAP login operations

import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP LOGIN command
final class LoginHandler: BaseIMAPCommandHandler<[Capability]>, IMAPCommandHandler, @unchecked Sendable {
    /// Collected capabilities from untagged responses
    private var capabilities: [Capability] = []
    
    	/// Handle a tagged OK response
	/// - Parameter response: The tagged response
	override func handleTaggedOKResponse(_ response: TaggedResponse) {
		// Call super to handle CLIENTBUG warnings
		super.handleTaggedOKResponse(response)
		
		// Check if we have collected capabilities from untagged responses
		let collectedCapabilities = lock.withLock { self.capabilities }
		
		if !collectedCapabilities.isEmpty {
			// If we have collected capabilities from untagged responses, use those
			succeedWithResult(collectedCapabilities)
		} else if case .ok(let responseText) = response.state, let code = responseText.code, case .capability(let capabilities) = code {
			// If the OK response contains capabilities, use those
			succeedWithResult(capabilities)
		} else {
			// No capabilities found
			succeedWithResult([])
		}
	}
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.loginFailed(String(describing: response.state)))
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
        
        return false
    }
} 
