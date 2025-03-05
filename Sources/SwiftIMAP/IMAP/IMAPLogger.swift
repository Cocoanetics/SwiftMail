// IMAPLogger.swift
// A combined channel handler that logs both outgoing and incoming IMAP messages

import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// A combined channel handler that logs both outgoing and incoming IMAP messages
public final class IMAPLogger: ChannelDuplexHandler, @unchecked Sendable {
    public typealias OutboundIn = Any
    public typealias OutboundOut = Any
    public typealias InboundIn = Response
    public typealias InboundOut = Response
    
    private let outboundLogger: Logging.Logger
    private let inboundLogger: Logging.Logger
    
    // Thread-safe storage for aggregating inbound messages
    private let lock = NIOLock()
    private var inboundBuffer: [String] = []
    
    /// Initialize a new IMAP logger
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
        
        // Check if this is an IOData type (which contains raw bytes)
        if let ioData = command as? IOData {
            // Extract the ByteBuffer from IOData and convert to string
            switch ioData {
                case .byteBuffer(let buffer):
                    // Use the ByteBuffer extension to get a string value
                    let commandString = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? "<Binary data>"
                    outboundLogger.trace("\(commandString)")
                case .fileRegion:
                    outboundLogger.trace("<File region data>")
            }
        } else if let debuggable = command as? CustomDebugStringConvertible {
            // Use debugDescription for more detailed information about the command
            outboundLogger.trace("\(debuggable.debugDescription)")
        } else {
            // Fallback to standard description
            outboundLogger.trace("\(String(describing: command))")
        }
        
        // Forward the data to the next handler
        context.write(data, promise: promise)
    }
    
    /// Log incoming responses and forward them to the next handler
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        
        // Add the response to the buffer
        bufferInboundResponse(response.debugDescription)
        
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
