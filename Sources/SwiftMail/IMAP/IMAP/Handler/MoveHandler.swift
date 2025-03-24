// MoveHandler.swift
// Handler for IMAP MOVE command

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/** Handler for IMAP MOVE command */
final class MoveHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {
    /** The result type for this handler */
    typealias ResultType = Void
    
    /**
     Process an incoming response
     - Parameter response: The response to process
     - Returns: Whether the response was handled by this handler
     */
    override func processResponse(_ response: Response) -> Bool {
        // Log the response using the base handler
        let baseHandled = super.processResponse(response)
        
        // Check if this is our tagged response
        if case .tagged(let taggedResponse) = response, taggedResponse.tag == commandTag {
            if case .ok = taggedResponse.state {
                // The move was successful
                succeedWithResult(())
            } else {
                // The move failed
                failWithError(IMAPError.commandFailed("Move failed: \(String(describing: taggedResponse.state))"))
            }
            return true
        }
        
        // Not our tagged response
        return baseHandled
    }
} 
