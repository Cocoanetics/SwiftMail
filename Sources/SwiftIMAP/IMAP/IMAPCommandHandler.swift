// IMAPCommandHandler.swift
// Protocol for command-specific IMAP handlers

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Protocol for command-specific IMAP handlers
/// These handlers are added to the pipeline when a command is sent and removed when the response is received
public protocol IMAPCommandHandler: ChannelInboundHandler where InboundIn == Response {
    /// The tag associated with this command
    var commandTag: String { get }
    
    /// Whether this handler has completed processing
    var isCompleted: Bool { get }
    
    /// The timeout for this command in seconds
    var timeoutSeconds: Int { get }
    
    /// Set up the timeout for this command
    /// - Parameter eventLoop: The event loop to schedule the timeout on
    func setupTimeout(on eventLoop: EventLoop)
    
    /// Cancel the timeout for this command
    func cancelTimeout()
    
    /// Handle the completion of this command
    /// - Parameter context: The channel handler context
    func handleCompletion(context: ChannelHandlerContext)
}

/// Base implementation of IMAPCommandHandler with common functionality
public class BaseIMAPCommandHandler: IMAPCommandHandler, RemovableChannelHandler {
    public typealias InboundIn = Response
    public typealias InboundOut = Response
    
    /// The tag associated with this command
    public let commandTag: String
    
    /// Whether this handler has completed processing
    public private(set) var isCompleted: Bool = false
    
    /// The timeout for this command in seconds
    public let timeoutSeconds: Int
    
    /// The timeout task
    private var timeoutTask: Scheduled<Void>?
    
    /// Logger for IMAP responses
    internal let logger: Logger
    
    /// Lock for thread-safe access to mutable properties
    internal let lock = NIOLock()
    
    /// Buffer for logging during command processing
    private var logBuffer: [String] = []
    
    /// Initialize a new command handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    public init(commandTag: String, timeoutSeconds: Int = 10, logger: Logger) {
        self.commandTag = commandTag
        self.timeoutSeconds = timeoutSeconds
        self.logger = logger
    }
    
    /// Set up the timeout for this command
    /// - Parameter eventLoop: The event loop to schedule the timeout on
    public func setupTimeout(on eventLoop: EventLoop) {
        timeoutTask = eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) { [weak self] in
            self?.handleTimeout()
        }
    }
    
    /// Cancel the timeout for this command
    public func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }
    
    /// Handle a timeout for this command
    /// This method should be overridden by subclasses
    public func handleTimeout() {
        // Default implementation does nothing
        flushLogBuffer()
    }
    
    /// Handle the completion of this command
    /// - Parameter context: The channel handler context
    public func handleCompletion(context: ChannelHandlerContext) {
        lock.withLock {
            isCompleted = true
        }
        
        // Flush any remaining logs before removing the handler
        flushLogBuffer()
        
        // Remove this handler from the pipeline
        context.pipeline.removeHandler(self, promise: nil)
    }
    
    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    public func processResponse(_ response: Response) -> Bool {
        // Buffer the response for logging
        bufferLog(response.debugDescription)
        
        // Check if this is a tagged response that matches our command tag
        if case .tagged(let taggedResponse) = response, taggedResponse.tag == commandTag {
            // This is our response, mark as completed
            return true
        }
        
        // Not our response
        return false
    }
    
    /// Add a message to the log buffer
    fileprivate func bufferLog(_ message: String) {
        lock.withLock {
            logBuffer.append(message)
        }
    }
    
    /// Flush the log buffer to the logger
    fileprivate func flushLogBuffer() {
        lock.withLock {
            if !logBuffer.isEmpty {
                let combinedLog = logBuffer.joined(separator: "\n")
                logger.debug("\(combinedLog, privacy: .public)\n")
                logBuffer.removeAll()
            }
        }
    }
    
    /// Channel read method from ChannelInboundHandler
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        
        // Process the response (which will buffer it for logging)
        let handled = processResponse(response)
        
        // If this was our tagged response, handle completion
        if handled {
            handleCompletion(context: context)
        }
        
        // Always forward the response to the next handler
        context.fireChannelRead(data)
    }
    
    /// Error caught method from ChannelInboundHandler
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Handle the error
        handleError(error)
        
        // Forward the error to the next handler
        context.fireErrorCaught(error)
    }
    
    /// Handle an error
    /// This method should be overridden by subclasses
    public func handleError(_ error: Error) {
        // Flush logs before handling the error
        flushLogBuffer()
        
        // Default implementation does nothing else
    }
} 
