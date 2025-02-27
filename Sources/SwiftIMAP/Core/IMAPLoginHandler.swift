// IMAPLoginHandler.swift
// A specialized handler for IMAP login operations

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP LOGIN command
public final class IMAPLoginHandler: BaseIMAPCommandHandler, @unchecked Sendable {
    /// Promise for the login operation
    private let loginPromise: EventLoopPromise<Void>
    
    /// Initialize a new login handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - loginPromise: The promise to fulfill when the login completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    public init(commandTag: String, loginPromise: EventLoopPromise<Void>, timeoutSeconds: Int = 5, logger: Logger) {
        self.loginPromise = loginPromise
        super.init(commandTag: commandTag, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Handle a timeout for this command
    override public func handleTimeout() {
        loginPromise.fail(IMAPError.timeout)
    }
    
    /// Handle an error
    override public func handleError(_ error: Error) {
        loginPromise.fail(error)
    }
    
    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override public func processResponse(_ response: Response) -> Bool {
        // First check if this is our tagged response
        if case .tagged(let taggedResponse) = response, taggedResponse.tag == commandTag {
            if case .ok = taggedResponse.state {
                loginPromise.succeed(())
            } else {
                loginPromise.fail(IMAPError.loginFailed(String(describing: taggedResponse.state)))
            }
            return true
        }
        
        // Not our tagged response
        return false
    }
} 