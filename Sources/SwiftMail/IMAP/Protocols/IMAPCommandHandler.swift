// IMAPCommandHandler.swift
// Protocol for IMAP command handlers

import Foundation
import Logging
import NIO
@preconcurrency import NIOIMAP
import NIOIMAPCore

/// Protocol for IMAP command handlers
protocol IMAPCommandHandler: ChannelInboundHandler, RemovableChannelHandler, Sendable where ResultType: Sendable {
    associatedtype ResultType

    /// Initialize the handler
    /// - Parameters:
    ///   - commandTag: The tag for the command (optional)
    ///   - promise: The promise to fulfill with the result
    init(commandTag: String, promise: EventLoopPromise<ResultType>)

    /// Get the untagged responses collected during command execution
    var untaggedResponses: [Response] { get }

    /// Whether the handler has already completed and removed itself from the pipeline.
    var isCompleted: Bool { get }
}
