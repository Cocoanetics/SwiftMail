// GreetingHandler.swift
// Handler for IMAP server greeting

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP server greeting
public final class GreetingHandler: BaseIMAPCommandHandler, @unchecked Sendable {
    /// Promise for the greeting operation
    private let greetingPromise: EventLoopPromise<Void>
    
    /// Initialize a new greeting handler
    /// - Parameters:
    ///   - greetingPromise: The promise to fulfill when the greeting is received
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    public init(greetingPromise: EventLoopPromise<Void>, timeoutSeconds: Int = 5, logger: Logger) {
        self.greetingPromise = greetingPromise
        // Greeting doesn't have a command tag, so we use an empty string
        super.init(commandTag: "", timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Handle a timeout for this command
    override public func handleTimeout() {
        greetingPromise.fail(IMAPError.timeout)
    }
    
    /// Handle an error
    override public func handleError(_ error: Error) {
        greetingPromise.fail(error)
    }
    
    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override public func processResponse(_ response: Response) -> Bool {
        // Call the superclass method to buffer the response for logging
        _ = super.processResponse(response)
        
        // Server greeting is typically an untagged OK response
        if case .untagged(let untaggedResponse) = response {
            if case .conditionalState(let state) = untaggedResponse, case .ok = state {
                // Succeed the promise and return true to indicate completion
                greetingPromise.succeed(())
                return true
            }
        }
        
        // Not the greeting
        return false
    }
} 
