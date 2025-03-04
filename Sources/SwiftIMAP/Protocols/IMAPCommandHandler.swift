// IMAPCommandHandler.swift
// Protocol for IMAP command handlers

import Foundation
import NIO
import Logging

/// Protocol for IMAP command handlers
public protocol IMAPCommandHandler: ChannelInboundHandler, TimeoutHandler {
    associatedtype ResultType
    
    /// Logger for IMAP responses
    var logger: Logger? { get set }
    
    /// Initialize the handler
    /// - Parameters:
    ///   - commandTag: The tag for the command (optional)
    ///   - promise: The promise to fulfill with the result
    ///   - timeoutSeconds: The timeout in seconds
    init(commandTag: String, promise: EventLoopPromise<ResultType>, timeoutSeconds: Int)
}
