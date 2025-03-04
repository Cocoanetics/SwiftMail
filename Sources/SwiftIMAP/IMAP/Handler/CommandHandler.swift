// CommandHandler.swift
// Protocol for command-specific IMAP handlers

import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Protocol for command-specific IMAP handlers
/// These handlers are added to the pipeline when a command is sent and removed when the response is received
public protocol CommandHandler: ChannelInboundHandler where InboundIn == Response {
    /// The tag associated with this command (optional)
    var commandTag: String? { get }
    
    /// Whether this handler has completed processing
    var isCompleted: Bool { get }
    
    /// Handle the completion of this command
    /// - Parameter context: The channel handler context
    func handleCompletion(context: ChannelHandlerContext)
}

/// Base implementation of CommandHandler with common functionality
public class BaseIMAPCommandHandler<ResultType>: CommandHandler, RemovableChannelHandler {
    public typealias InboundIn = Response
    public typealias InboundOut = Response
    
    /// The tag associated with this command (optional)
    public let commandTag: String?
    
    /// Whether this handler has completed processing
    public private(set) var isCompleted: Bool = false
    
    /// Logger for IMAP responses
    public var logger: Logger?
    
    /// Lock for thread-safe access to mutable properties
    internal let lock = NIOLock()
    
    /// Buffer for logging during command processing
    private var logBuffer: [String] = []
    
    /// Promise for the command result
    internal let promise: EventLoopPromise<ResultType>
    
    /// Initialize a new command handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the command completes
    public init(commandTag: String, promise: EventLoopPromise<ResultType>) {
        self.commandTag = commandTag
        self.promise = promise
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
    
    /// Succeed the promise with a result
    /// - Parameter result: The result to succeed with
    internal func succeedWithResult(_ result: ResultType) {
        promise.succeed(result)
    }
    
    /// Fail the promise with an error
    /// - Parameter error: The error to fail with
    internal func failWithError(_ error: Error) {
        promise.fail(error)
    }
    
    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    public func processResponse(_ response: Response) -> Bool {
        // Buffer the response for logging
        bufferLog(response.debugDescription)
        
        // If commandTag is nil, we're only interested in untagged responses
        if commandTag == nil {
            return handleUntaggedResponse(response)
        }
        
        // Check if this is a tagged response that matches our command tag
        if case .tagged(let taggedResponse) = response, taggedResponse.tag == commandTag {
            // Check the response status
            if case .ok = taggedResponse.state {
                // Subclasses should override handleTaggedOKResponse to handle the OK response
                handleTaggedOKResponse(taggedResponse)
            } else {
                logger?.debug("Tagged response is an error: \(String(describing: taggedResponse.state))")
                // Failed response, fail the promise with an error
                handleTaggedErrorResponse(taggedResponse)
            }
            return true
        }
        
        // Not our tagged response, see if subclasses want to handle untagged responses
        let handled = handleUntaggedResponse(response)
        return handled
    }
    
    /// Handle a tagged OK response
    /// Subclasses should override this method to handle successful responses
    /// - Parameter response: The tagged response
    open func handleTaggedOKResponse(_ response: TaggedResponse) {
        // Default implementation succeeds with Void for handlers that don't need a result
        // This only works for ResultType == Void, otherwise subclasses must override
        if ResultType.self == Void.self {
            succeedWithResult(() as! ResultType)
        } else {
            // If ResultType is not Void, subclasses must override this method
            fatalError("Subclasses must override handleTaggedOKResponse for non-Void result types")
        }
    }
    
    /// Handle a tagged error response
    /// Subclasses can override this method to handle error responses differently
    /// - Parameter response: The tagged response
    open func handleTaggedErrorResponse(_ response: TaggedResponse) {
        // Default implementation fails with a generic error
        failWithError(IMAPError.commandFailed(String(describing: response.state)))
    }
    
    /// Handle an untagged response
    /// Subclasses should override this method to handle untagged responses
    /// - Parameter response: The untagged response
    /// - Returns: Whether the response was handled by this handler
    open func handleUntaggedResponse(_ response: Response) -> Bool {
        // Default implementation doesn't handle untagged responses
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
                logger?.debug("\(combinedLog)\n")
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
        
        // Fail the promise with the error
        failWithError(error)
    }
} 
