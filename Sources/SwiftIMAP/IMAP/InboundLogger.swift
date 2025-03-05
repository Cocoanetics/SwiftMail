// InboundLogger.swift
// A channel handler that logs incoming IMAP responses

import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

/// A channel handler that logs incoming IMAP responses
public final class InboundLogger: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = Response
    public typealias InboundOut = Response
    
    private let logger: Logging.Logger
    
    /// Initialize a new inbound logger
    /// - Parameter logger: The logger to use for logging responses
    public init(logger: Logging.Logger) {
        self.logger = logger
    }
    
    /// Log incoming responses and forward them to the next handler
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        
        // Log the response at notice level to ensure visibility
        logger.trace("\(response.debugDescription)")
        
        // Forward the response to the next handler
        context.fireChannelRead(data)
    }
} 
