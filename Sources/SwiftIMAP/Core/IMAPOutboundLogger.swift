// IMAPOutboundLogger.swift
// A channel handler that logs outgoing IMAP commands

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

/// A channel handler that logs outgoing IMAP commands
public final class IMAPOutboundLogger: ChannelOutboundHandler, @unchecked Sendable {
    public typealias OutboundIn = Any
    public typealias OutboundOut = Any
    
    private let logger: Logger
    
    /// Initialize a new outbound logger
    /// - Parameter logger: The logger to use for logging commands
    public init(logger: Logger) {
        self.logger = logger
    }
    
    /// Log outgoing commands and forward them to the next handler
    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        // Try to extract the command from the data
        let command = unwrapOutboundIn(data)
        
        // Log the command with notice level for better visibility
        logger.notice("IMAP COMMAND: \(String(describing: command), privacy: .public)")
        
        // Forward the data to the next handler
        context.write(data, promise: promise)
    }
} 