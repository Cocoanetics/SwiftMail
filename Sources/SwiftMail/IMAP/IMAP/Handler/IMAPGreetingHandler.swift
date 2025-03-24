// IMAPGreetingHandler.swift
// Handler for IMAP server greeting

import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP server greeting
final class IMAPGreetingHandler: BaseIMAPCommandHandler<[Capability]>, IMAPCommandHandler, @unchecked Sendable {
    
    /// Process untagged responses to look for the server greeting
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override func handleUntaggedResponse(_ response: Response) -> Bool {
        // Server greeting is typically an untagged OK response
        if case .untagged(let untaggedResponse) = response {
            if case .conditionalState(let state) = untaggedResponse {
                if case .ok(let responseText) = state {
                    // Check if the OK response contains capabilities
                    if let code = responseText.code, case .capability(let capabilities) = code {
                        // Succeed the promise with the capabilities
                        succeedWithResult(capabilities)
                        return true
                    } else {
                        // No capabilities in the greeting, succeed with empty array
                        succeedWithResult([])
                        return true
                    }
                }
            }
        }
        
        // Not the greeting
        return false
    }
} 
