// MailLogger.swift
// A base class for mail protocol loggers that handles both outgoing and incoming messages

import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOIMAP

/// Base class for mail protocol loggers
class MailLogger: ChannelDuplexHandler, @unchecked Sendable {
    // Type definitions
    typealias OutboundIn = Any
    typealias OutboundOut = Any
    
    // These must be defined by subclasses
    typealias InboundIn = Any
    typealias InboundOut = Any
    
    // Common properties - using protected-like access
	let outboundLogger: Logging.Logger
	let inboundLogger: Logging.Logger
	let lock = NIOLock()
    
    // Make inboundBuffer accessible for modification by subclasses
	var inboundBuffer: [String] = []
    
    /// Initialize a new mail logger
    /// - Parameters:
    ///   - outboundLogger: Logger for outbound messages
    ///   - inboundLogger: Logger for inbound messages
	init(outboundLogger: Logging.Logger, inboundLogger: Logging.Logger) {
        self.outboundLogger = outboundLogger
        self.inboundLogger = inboundLogger
    }
    
    /// Add a response to the inbound buffer
	func bufferInboundResponse(_ message: String) {
        lock.withLock {
            inboundBuffer.append(message)
        }
    }
    
    /// Flush the inbound buffer
	func flushInboundBuffer() {
        lock.withLock {
            if !inboundBuffer.isEmpty {
				let lines = inboundBuffer.joined(separator: ", ")
				inboundLogger.trace(Logger.Message(stringLiteral: lines))
                inboundBuffer.removeAll()
            }
        }
    }
    
    /// Check if there are buffered messages
	func hasBufferedMessages() -> Bool {
        lock.withLock {
            return !inboundBuffer.isEmpty
        }
    }
    
    /// Helper method for extracting string representation from various types
	func stringRepresentation(from command: Any) -> String {
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
        } else if let message = command as? NIOIMAP.IMAPClientHandler.Message {
            if case .part(let streamPart) = message {
                return streamPart.debugDescription
            } else {
                return String(describing: message)
            }
        } else if let debuggable = command as? CustomDebugStringConvertible {
            return debuggable.debugDescription
        } else {
            return String(describing: command)
        }
    }
    
    // Abstract methods that must be implemented by subclasses
	func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        fatalError("write(context:data:promise:) must be implemented by subclasses")
    }
    
	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        fatalError("channelRead(context:data:) must be implemented by subclasses")
    }
} 
