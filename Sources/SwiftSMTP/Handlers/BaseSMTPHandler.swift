import Foundation
import NIOCore
import Logging

/// Base class for SMTP command handlers that provides common functionality
open class BaseSMTPHandler<T>: SMTPCommandHandler, LoggableHandler {
    public typealias ResultType = T
    
    /// The command tag (optional for SMTP)
    public let commandTag: String?
    
    /// The promise that will be fulfilled when the command completes
    public let promise: EventLoopPromise<ResultType>
    
    /// The timeout in seconds for this command
    public let timeoutSeconds: Int
    
    /// Logger for handler operations
    public var logger: Logger
    
    /// Initialize a new handler
    /// - Parameters:
    ///   - commandTag: Optional tag for the command (not commonly used in SMTP but included for consistency)
    ///   - promise: The promise to fulfill when the command completes
    ///   - timeoutSeconds: The timeout in seconds for this command
    public required init(commandTag: String?, promise: EventLoopPromise<ResultType>, timeoutSeconds: Int = 30) {
        self.commandTag = commandTag
        self.promise = promise
        self.timeoutSeconds = timeoutSeconds
        self.logger = Logger(label: "com.cocoanetics.SwiftSMTP.Handler.\(String(describing: type(of: self)))")
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
    /// - Parameter response: The successful response
    open func handleSuccess(response: SMTPResponse) {
        // Default implementation fails with an error since subclasses should override this
        promise.fail(SMTPError.connectionFailed("BaseSMTPHandler.handleSuccess not implemented"))
    }
    
    /// Handle an error response
    /// - Parameter response: The error response
    open func handleError(response: SMTPResponse) {
        promise.fail(SMTPError.connectionFailed("SMTP error: \(response.code) \(response.message)"))
    }
    
    /// Default implementation for createHandler
    public static func createHandler(commandTag: String?, promise: EventLoopPromise<ResultType>, timeoutSeconds: Int) -> Self {
        return Self(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds)
    }
    
    /// Cancel any active timeout
    open func cancelTimeout() {
        // This is a placeholder for handler timeout cancellation
        // Implement actual timeout cancellation logic when needed
    }
} 
