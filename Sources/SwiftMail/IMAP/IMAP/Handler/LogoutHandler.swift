// LogoutHandler.swift
// Handler for IMAP LOGOUT command

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP LOGOUT command
final class LogoutHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {

    /// Handle untagged responses specific to LOGOUT.
    ///
    /// Servers typically send a `BYE` response during the logout sequence.
    /// The default implementation treats this as a connection failure, so we
    /// override it to simply ignore the `BYE` and wait for the tagged `OK`.
    override func handleUntaggedResponse(_ response: Response) -> Bool {
        if case .untagged(let payload) = response,
           case .conditionalState(let status) = payload,
           case .bye = status {
            // Ignore BYE during logout and continue processing
            return false
        }

        return super.handleUntaggedResponse(response)
    }

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
