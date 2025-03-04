// LogoutHandler.swift
// Handler for IMAP LOGOUT command

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP LOGOUT command
public final class LogoutHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler {
    /// Initialize a new logout handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the logout completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    override public init(commandTag: String, promise: EventLoopPromise<Void>, timeoutSeconds: Int = 5) {
        super.init(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds)
    }
    
    /// Handle a timeout for this command
    override public func handleTimeout() {
        super.handleTimeout()
    }
    
    /// Handle an error
    override public func handleError(_ error: Error) {
        super.handleError(error)
    }
    
    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override public func processResponse(_ response: Response) -> Bool {
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
