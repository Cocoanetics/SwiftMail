// IMAPLogoutHandler.swift
// Handler for IMAP LOGOUT command

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP LOGOUT command
public final class IMAPLogoutHandler: BaseIMAPCommandHandler, @unchecked Sendable {
    /// Promise for the logout operation
    private let logoutPromise: EventLoopPromise<Void>
    
    /// Initialize a new logout handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - logoutPromise: The promise to fulfill when the logout completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    public init(commandTag: String, logoutPromise: EventLoopPromise<Void>, timeoutSeconds: Int = 5, logger: Logger) {
        self.logoutPromise = logoutPromise
        super.init(commandTag: commandTag, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Handle a timeout for this command
    override public func handleTimeout() {
        logoutPromise.fail(IMAPError.timeout)
    }
    
    /// Handle an error
    override public func handleError(_ error: Error) {
        logoutPromise.fail(error)
    }
    
    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override public func processResponse(_ response: Response) -> Bool {
        // First check if this is our tagged response
        if case .tagged(let taggedResponse) = response, taggedResponse.tag == commandTag {
            if case .ok = taggedResponse.state {
                logoutPromise.succeed(())
            } else {
                logoutPromise.fail(IMAPError.logoutFailed(String(describing: taggedResponse.state)))
            }
            return true
        }
        
        // Not our tagged response
        return false
    }
} 