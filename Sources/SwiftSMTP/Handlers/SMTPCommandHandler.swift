import Foundation
import NIOCore
import Logging

/// Protocol for SMTP command handlers
public protocol SMTPCommandHandler {
    /// The result type for this handler
    associatedtype ResultType
    
    /// Optional tag for the command (rarely used in SMTP but included for consistency)
    var commandTag: String? { get }
    
    /// The promise that will be fulfilled when the command completes
    var promise: EventLoopPromise<ResultType> { get }
    
    /// The timeout in seconds for this command
    var timeoutSeconds: Int { get }
    
    /// Process a response from the server
    /// - Parameter response: The response to process
    /// - Returns: Whether the handler is complete
    func processResponse(_ response: SMTPResponse) -> Bool
    
    /// Create a handler with the specified parameters
    /// - Parameters:
    ///   - commandTag: Optional tag for the command
    ///   - promise: The promise to fulfill when the command completes
    ///   - timeoutSeconds: The timeout in seconds for this command
    /// - Returns: A new handler instance
    static func createHandler(commandTag: String?, promise: EventLoopPromise<ResultType>, timeoutSeconds: Int) -> Self
    
    /// Required initializer for creating handler instances
    /// - Parameters:
    ///   - commandTag: Optional tag for the command
    ///   - promise: The promise to fulfill when the command completes
    ///   - timeoutSeconds: The timeout in seconds for this command
    init(commandTag: String?, promise: EventLoopPromise<ResultType>, timeoutSeconds: Int)
}

/// Protocol for handlers that can have a logger set
public protocol LoggableHandler {
    /// Logger for handler operations
    var logger: Logger { get set }
}
