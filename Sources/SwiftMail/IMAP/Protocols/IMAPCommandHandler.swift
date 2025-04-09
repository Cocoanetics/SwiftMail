// IMAPCommandHandler.swift
// Protocol for IMAP command handlers

import Foundation
import NIO
import Logging

/// Protocol for IMAP command handlers
protocol IMAPCommandHandler: ChannelInboundHandler, Sendable {
    associatedtype ResultType
    
    /// Initialize the handler
    /// - Parameters:
    ///   - commandTag: The tag for the command (optional)
    ///   - promise: The promise to fulfill with the result
    init(commandTag: String, promise: EventLoopPromise<ResultType>)
}
