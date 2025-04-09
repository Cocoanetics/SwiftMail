// LogoutHandler.swift
// Handler for IMAP LOGOUT command

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP LOGOUT command
final class LogoutHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {

    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override func processResponse(_ response: Response) -> Bool {
        // Log the response
        let baseHandled = super.processResponse(response)
        
        // First check if this is our tagged response
        if case .tagged(let taggedResponse) = response, taggedResponse.tag == commandTag {
            if case .ok = taggedResponse.state {
                succeedWithResult(())
            } else {
                failWithError(IMAPError.logoutFailed(String(describing: taggedResponse.state)))
            }
            return true
        }
        
        // Not our tagged response
        return baseHandled
    }
} 
