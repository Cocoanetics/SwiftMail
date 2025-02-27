// GreetingHandler.swift
// Handler for IMAP server greeting

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP server greeting
public final class GreetingHandler: BaseIMAPCommandHandler<Void>, @unchecked Sendable {
    /// Initialize a new greeting handler
    /// - Parameters:
    ///   - greetingPromise: The promise to fulfill when the greeting is received
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    public init(greetingPromise: EventLoopPromise<Void>, timeoutSeconds: Int = 5, logger: Logger) {
        // Greeting doesn't have a command tag, so we use an empty string
        super.init(commandTag: "", promise: greetingPromise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Process untagged responses to look for the server greeting
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override public func handleUntaggedResponse(_ response: Response) -> Bool {
        // Server greeting is typically an untagged OK response
        if case .untagged(let untaggedResponse) = response {
            if case .conditionalState(let state) = untaggedResponse, case .ok = state {
                // Succeed the promise
                succeedWithResult(())
                return true
            }
        }
        
        // Not the greeting
        return false
    }
} 
