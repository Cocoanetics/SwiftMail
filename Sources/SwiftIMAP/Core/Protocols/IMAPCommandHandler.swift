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
    
    /// Create a handler for the command
    /// - Parameters:
    ///   - commandTag: The tag for the command
    ///   - promise: The promise to fulfill with the result
    ///   - timeoutSeconds: The timeout in seconds
    /// - Returns: A handler for the command
    static func createHandler(
        commandTag: String,
        promise: EventLoopPromise<ResultType>,
        timeoutSeconds: Int
    ) -> Self
    
    /// Initialize the handler
    /// - Parameters:
    ///   - commandTag: The tag for the command
    ///   - promise: The promise to fulfill with the result
    ///   - timeoutSeconds: The timeout in seconds
    init(commandTag: String, promise: EventLoopPromise<ResultType>, timeoutSeconds: Int)
}

// Default implementation of createHandler
public extension IMAPCommandHandler {
    static func createHandler(
        commandTag: String,
        promise: EventLoopPromise<ResultType>,
        timeoutSeconds: Int
    ) -> Self {
        let handler = Self.init(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds)
        let eventLoop = promise.futureResult.eventLoop
        handler.setupTimeout(on: eventLoop)
        return handler
    }
} 
