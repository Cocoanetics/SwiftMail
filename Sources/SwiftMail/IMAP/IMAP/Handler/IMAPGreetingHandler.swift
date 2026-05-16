// IMAPGreetingHandler.swift
// Handler for IMAP server greeting

import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
@preconcurrency import NIOIMAP
import NIOIMAPCore

/// Handler for IMAP server greeting
final class IMAPGreetingHandler: BaseIMAPCommandHandler<[Capability]>, IMAPCommandHandler, @unchecked Sendable {
    /// Process untagged responses to look for the server greeting
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override func handleUntaggedResponse(_ response: Response) -> Bool {
        // Server greeting is typically an untagged OK response
        if case let .untagged(untaggedResponse) = response {
            if case let .conditionalState(state) = untaggedResponse {
                if case let .ok(responseText) = state {
                    // Check if the OK response contains capabilities
                    if let code = responseText.code, case let .capability(capabilities) = code {
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
