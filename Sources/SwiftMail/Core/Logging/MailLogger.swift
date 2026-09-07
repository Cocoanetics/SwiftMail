// MailLogger.swift
// A base class for mail protocol loggers that handles both outgoing and incoming messages

import Foundation
import Logging
import NIO
import NIOIMAP

/// Base class for mail protocol loggers
class MailLogger: ChannelDuplexHandler, @unchecked Sendable {
    static let maximumInboundBufferEntries = 256
    static let maximumInboundBufferBytes = 64 * 1024

    // Type definitions
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    // These must be defined by subclasses
    typealias InboundIn = Any
    typealias InboundOut = Any

    // Common properties - using protected-like access
    let outboundLogger: Logging.Logger
    let inboundLogger: Logging.Logger
    let lock = NSRecursiveLock()

    // Make inboundBuffer accessible for modification by subclasses
    var inboundBuffer: [String] = []
    private(set) var inboundBufferByteCount = 0
    private(set) var droppedInboundResponseCount = 0

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
            let byteCount = message.utf8.count
            guard inboundBuffer.count < Self.maximumInboundBufferEntries,
                  byteCount <= Self.maximumInboundBufferBytes - inboundBufferByteCount else {
                droppedInboundResponseCount += 1
                return
            }
            inboundBuffer.append(message)
            inboundBufferByteCount += byteCount
        }
    }

    /// Flush the inbound buffer
    func flushInboundBuffer() {
        lock.withLock {
            if !inboundBuffer.isEmpty || droppedInboundResponseCount > 0 {
                var lines = inboundBuffer.joined(separator: ", ")
                if droppedInboundResponseCount > 0 {
                    let omission = "<\(droppedInboundResponseCount) responses omitted>"
                    lines = lines.isEmpty ? omission : "\(lines), \(omission)"
                }
                inboundLogger.trace(Logger.Message(stringLiteral: lines))
                inboundBuffer.removeAll()
                inboundBufferByteCount = 0
                droppedInboundResponseCount = 0
            }
        }
    }

    /// Check if there are buffered messages
    func hasBufferedMessages() -> Bool {
        lock.withLock {
            return !inboundBuffer.isEmpty || droppedInboundResponseCount > 0
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

private extension NSRecursiveLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
