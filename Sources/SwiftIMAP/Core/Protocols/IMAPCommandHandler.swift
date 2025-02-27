// IMAPCommandHandler.swift
// Protocol for IMAP command handlers

import Foundation
import os.log
import NIO

/// Protocol for IMAP command handlers
public protocol IMAPCommandHandler: ChannelInboundHandler, TimeoutHandler {
    associatedtype ResultType
    
    /// Create a handler for the command
    /// - Parameters:
    ///   - commandTag: The tag for the command
    ///   - promise: The promise to fulfill with the result
    ///   - timeoutSeconds: The timeout in seconds
    ///   - logger: The logger to use
    /// - Returns: A handler for the command
    static func createHandler(
        commandTag: String,
        promise: EventLoopPromise<ResultType>,
        timeoutSeconds: Int,
        logger: Logger
    ) -> Self
} 