// OutboundLogger.swift
// A channel handler that logs outgoing SMTP commands

import Foundation
import Logging
import NIO
import NIOCore

/// A channel handler that logs outgoing SMTP commands
public final class OutboundLogger: ChannelOutboundHandler, @unchecked Sendable {
    public typealias OutboundIn = Any
    public typealias OutboundOut = Any
    
    private let logger: Logging.Logger
    
    /// Initialize a new outbound logger
    /// - Parameter logger: The logger to use for logging commands
    public init(logger: Logging.Logger) {
        self.logger = logger
    }
    
    /// Log outgoing commands and forward them to the next handler
    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        // Try to extract the command from the data
        let command = unwrapOutboundIn(data)
        
        // Check if this is an IOData type (which contains raw bytes)
        if let ioData = command as? IOData {
            // Extract the ByteBuffer from IOData and convert to string
            switch ioData {
                case .byteBuffer(let buffer):
                    // Use the ByteBuffer extension to get a string value
                    let commandString = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? "<Binary data>"
                    logger.trace("\(commandString)")
                case .fileRegion:
                    logger.trace("<File region data>")
            }
        } else if let debuggable = command as? CustomDebugStringConvertible {
            // Use debugDescription for more detailed information about the command
            logger.trace("\(debuggable.debugDescription)")
        } else {
            // Fallback to standard description
            logger.trace("\(String(describing: command))")
        }
        
        // Forward the data to the next handler
        context.write(data, promise: promise)
    }
} 
