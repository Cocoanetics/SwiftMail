// MailLogger.swift
// A base class for mail protocol loggers that handles both outgoing and incoming messages

import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers

/// Base class for mail protocol loggers
open class MailLogger: ChannelDuplexHandler, @unchecked Sendable {
    // Type definitions
    public typealias OutboundIn = Any
    public typealias OutboundOut = Any
    
    // These must be defined by subclasses
    public typealias InboundIn = Any
    public typealias InboundOut = Any
    
    // Common properties - using protected-like access
    public let outboundLogger: Logging.Logger
    public let inboundLogger: Logging.Logger
    public let lock = NIOLock()
    
    // Make inboundBuffer accessible for modification by subclasses
    public var inboundBuffer: [String] = []
    
    /// Initialize a new mail logger
    /// - Parameters:
    ///   - outboundLogger: Logger for outbound messages
    ///   - inboundLogger: Logger for inbound messages
    public init(outboundLogger: Logging.Logger, inboundLogger: Logging.Logger) {
        self.outboundLogger = outboundLogger
        self.inboundLogger = inboundLogger
    }
    
    /// Add a response to the inbound buffer
    open func bufferInboundResponse(_ message: String) {
        lock.withLock {
            inboundBuffer.append(message)
        }
    }
    
    /// Flush the inbound buffer
    open func flushInboundBuffer() {
        lock.withLock {
            if !inboundBuffer.isEmpty {
				let lines = inboundBuffer.joined(separator: ", ")
				inboundLogger.trace(Logger.Message(stringLiteral: lines))
                inboundBuffer.removeAll()
            }
        }
    }
    
    /// Check if there are buffered messages
    open func hasBufferedMessages() -> Bool {
        lock.withLock {
            return !inboundBuffer.isEmpty
        }
    }
    
    /// Helper method for extracting string representation from various types
    open func stringRepresentation(from command: Any) -> String {
        if let ioData = command as? IOData {
            switch ioData {
            case .byteBuffer(let buffer):
                if let string = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                    return string
                } else {
                    return "<binary data of size \(buffer.readableBytes)>"
                }
            case .fileRegion:
                return "<file region>"
            }
        } else if let string = command as? String {
            return string
        } else if let debuggable = command as? CustomDebugStringConvertible {
            return debuggable.debugDescription
        } else {
            return String(describing: command)
        }
    }
    
    // Abstract methods that must be implemented by subclasses
    open func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        fatalError("write(context:data:promise:) must be implemented by subclasses")
    }
    
    open func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        fatalError("channelRead(context:data:) must be implemented by subclasses")
    }
} 
