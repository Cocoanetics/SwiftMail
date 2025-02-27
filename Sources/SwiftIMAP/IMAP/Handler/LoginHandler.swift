// LoginHandler.swift
// A specialized handler for IMAP login operations

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP LOGIN command
public final class LoginHandler: BaseIMAPCommandHandler<Void>, @unchecked Sendable {
    /// Initialize a new login handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - loginPromise: The promise to fulfill when the login completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    public init(commandTag: String, loginPromise: EventLoopPromise<Void>, timeoutSeconds: Int = 5, logger: Logger) {
        super.init(commandTag: commandTag, promise: loginPromise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override public func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.loginFailed(String(describing: response.state)))
    }
} 
