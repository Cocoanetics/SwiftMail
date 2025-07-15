// IMAPCommandHandler.swift
// Protocol for IMAP command handlers

import Foundation
import NIO
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore

/// Protocol for IMAP command handlers
protocol IMAPCommandHandler: ChannelInboundHandler, Sendable where ResultType: Sendable {
    associatedtype ResultType
    
    /// Initialize the handler
    /// - Parameters:
    ///   - commandTag: The tag for the command (optional)
    ///   - promise: The promise to fulfill with the result
    init(commandTag: String, promise: EventLoopPromise<ResultType>)
    
    /// Get the untagged responses collected during command execution
    var untaggedResponses: [Response] { get }
}
