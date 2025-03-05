// SMTPLogger.swift
// A combined channel handler that logs both outgoing and incoming SMTP messages

import Foundation
import Logging
import NIO
import NIOCore
import NIOConcurrencyHelpers

/// A combined channel handler that logs both outgoing and incoming SMTP messages
public final class SMTPLogger: ChannelDuplexHandler, @unchecked Sendable {
    public typealias OutboundIn = Any
    public typealias OutboundOut = Any
    public typealias InboundIn = String
    public typealias InboundOut = String
    
    private let outboundLogger: Logging.Logger
    private let inboundLogger: Logging.Logger
    
    // Thread-safe storage for aggregating inbound messages
    private let lock = NIOLock()
    private var inboundBuffer: [String] = []
    
    /// Initialize a new SMTP logger
    /// - Parameters:
    ///   - outboundLogger: The logger to use for outgoing commands
    ///   - inboundLogger: The logger to use for incoming responses
    public init(outboundLogger: Logging.Logger, inboundLogger: Logging.Logger) {
        self.outboundLogger = outboundLogger
        self.inboundLogger = inboundLogger
    }
    
    /// Log outgoing commands and forward them to the next handler
    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        // Try to extract the command from the data
        let command = unwrapOutboundIn(data)
        
		let commandString: String
		
        // Check if this is an IOData type (which contains raw bytes)
        if let ioData = command as? IOData {
            // Extract the ByteBuffer from IOData and convert to string
            switch ioData {
                case .byteBuffer(let buffer):
                    // Use the ByteBuffer extension to get a string value
                    commandString = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? "<Binary data>"
                    
                case .fileRegion:
					commandString = "<File region data>"
            }
        } else if let debuggable = command as? CustomDebugStringConvertible {
            // Use debugDescription for more detailed information about the command
			commandString = debuggable.debugDescription
        } else {
            // Fallback to standard description
			commandString = String(describing: command)
        }
		
		// Redact sensitive information in AUTH commands
		if commandString.hasPrefix("AUTH") || commandString.hasPrefix("auth") {
			outboundLogger.trace("AUTH [credentials redacted]")
		} else {
			outboundLogger.trace("\(commandString)")
		}
        
        // Forward the data to the next handler
        context.write(data, promise: promise)
    }
    
    /// Log incoming responses and forward them to the next handler
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let responseString = unwrapInboundIn(data)
        
		bufferInboundResponse(responseString)
        
        // Forward the response to the next handler
        context.fireChannelRead(data)
    }
    
    /// Add a response to the inbound buffer
    private func bufferInboundResponse(_ message: String) {
        lock.withLock {
            inboundBuffer.append(message)
        }
    }
    
    /// Flush the inbound buffer to the logger
    /// This should be called when a complete response has been received
    public func flushInboundBuffer() {
        lock.withLock {
            if !inboundBuffer.isEmpty {
                let combinedLog = inboundBuffer.joined(separator: "\n")
                inboundLogger.trace("\(combinedLog)")
                inboundBuffer.removeAll()
            }
        }
    }
    
    /// Check if there are any buffered inbound messages
    public var hasBufferedMessages: Bool {
        lock.withLock {
            return !inboundBuffer.isEmpty
        }
    }
} 
