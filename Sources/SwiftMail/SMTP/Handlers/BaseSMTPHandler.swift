import Foundation
import NIOCore
import Logging

/// Base class for SMTP command handlers that provides common functionality
class BaseSMTPHandler<T: Sendable>: ChannelInboundHandler, RemovableChannelHandler, SMTPCommandHandler, @unchecked Sendable {
    typealias InboundIn = SMTPResponse
    typealias InboundOut = Never
    typealias ResultType = T
    
    /// The command tag (optional for SMTP)
    public let commandTag: String?
    
    /// The promise that will be fulfilled when the command completes
    public let promise: EventLoopPromise<ResultType>
    
    /// Initialize a new handler
    /// - Parameters:
    ///   - commandTag: Optional tag for the command (not commonly used in SMTP but included for consistency)
    ///   - promise: The promise to fulfill when the command completes
    public required init(commandTag: String?, promise: EventLoopPromise<ResultType>) {
        self.commandTag = commandTag
        self.promise = promise
    }
    
    /// Process a response line from the server
    /// - Parameter response: The response line to process
    /// - Returns: Whether the handler is complete
    open func processResponse(_ response: SMTPResponse) -> Bool {
        // Default implementation just checks for success/failure response codes
        // Subclasses should override this to handle command-specific responses
        
        if response.code >= 200 && response.code < 400 {
            // Success response (2xx or 3xx)
            handleSuccess(response: response)
            return true
        } else if response.code >= 400 {
            // Error response (4xx or 5xx)
            handleError(response: response)
            return true
        }
        
        return false // Not yet complete
    }
    
    /// Handle a successful response
    /// - Parameter response: The parsed SMTP response
    open func handleSuccess(response: SMTPResponse) {
        // Default implementation, subclasses should override
        promise.fail(SMTPError.connectionFailed("BaseSMTPHandler.handleSuccess not implemented"))
    }
    
    /// Handle an error response
    /// - Parameter response: The parsed SMTP response
    open func handleError(response: SMTPResponse) {
        // Default implementation, subclasses should override
        promise.fail(SMTPError.connectionFailed("SMTP error: \(response.code) \(response.message)"))
    }
    
    /// Cancel any active timeout
    open func cancelTimeout() {
        // This is a placeholder for handler timeout cancellation
        // Implement actual timeout cancellation logic when needed
    }
    
    // MARK: - ChannelInboundHandler Implementation
    
    /// Handle channel read events directly from the pipeline
    /// - Parameters:
    ///   - context: The channel handler context
    ///   - data: The data read from the channel
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        
        // Process the response directly
        let isComplete = processResponse(response)
        
        // If the handler is complete, remove it from the pipeline
        if isComplete {
            context.pipeline.removeHandler(self, promise: nil)
        }
    }
    
    /// Handle channel read complete events
    /// - Parameter context: The channel handler context
    public func channelReadComplete(context: ChannelHandlerContext) {
        // Flush any pending writes
        context.flush()
    }
    
    /// Handle channel inactive events
    /// - Parameter context: The channel handler context
    public func channelInactive(context: ChannelHandlerContext) {
        // If the channel becomes inactive, fail the promise with connection closed error
        // No need to check if it's fulfilled - Swift's promise system will ignore second attempts
        promise.fail(SMTPError.connectionFailed("Connection closed"))
    }
    
    /// Handle errors caught in the channel pipeline
    /// - Parameters:
    ///   - context: The channel handler context
    ///   - error: The error caught
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Fail the promise with the error
        promise.fail(error)
        
        // Remove this handler from the pipeline
        context.pipeline.removeHandler(self, promise: nil)
        
        // Forward the error to the next handler
        context.fireErrorCaught(error)
    }
    
    // MARK: - Helper Methods
    
    /// Fulfill the promise with the result
    /// - Parameter value: The value to fulfill the promise with
    internal func fulfill(_ value: T) {
        promise.succeed(value)
    }
    
    /// Fail the promise with an error
    /// - Parameter error: The error to fail the promise with
    internal func fail(_ error: Error) {
        promise.fail(error)
    }
    
    /// Called when the handler's future is successful
    /// Simply an interface to standardize our handler architecture
    public func onSuccess(_ value: T) {
        promise.succeed(value)
    }
    
    /// Called when the handler's future fails
    /// Simply an interface to standardize our handler architecture
    public func onFailure(_ error: Error) {
        promise.fail(error)
    }
} 
