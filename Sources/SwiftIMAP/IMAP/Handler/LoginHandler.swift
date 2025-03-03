// LoginHandler.swift
// A specialized handler for IMAP login operations

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP LOGIN command
public final class LoginHandler: BaseIMAPCommandHandler<[Capability]>, @unchecked Sendable {
    /// Collected capabilities from untagged responses
    private var capabilities: [Capability] = []
    
    /// Initialize a new login handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - loginPromise: The promise to fulfill when the login completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    public init(commandTag: String, loginPromise: EventLoopPromise<[Capability]>, timeoutSeconds: Int = 5, logger: Logger) {
        super.init(commandTag: commandTag, promise: loginPromise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Handle a tagged OK response
    /// - Parameter response: The tagged response
    override public func handleTaggedOKResponse(_ response: TaggedResponse) {
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
    override public func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.loginFailed(String(describing: response.state)))
    }
    
    /// Handle an untagged response
    /// - Parameter response: The untagged response
    /// - Returns: Whether the response was handled by this handler
    override public func handleUntaggedResponse(_ response: Response) -> Bool {
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
