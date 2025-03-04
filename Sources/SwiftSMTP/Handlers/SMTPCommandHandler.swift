import Foundation
import NIOCore
import Logging

/// Protocol defining the structure for SMTP command handlers
public protocol SMTPCommandHandler {
    /// The type of result this handler will produce
    associatedtype ResultType
    
    /// The command tag (optional for SMTP)
    var commandTag: String? { get }
    
    /// The promise that will be fulfilled when the command completes
    var promise: EventLoopPromise<ResultType> { get }
    
    /// The timeout in seconds for this command
    var timeoutSeconds: Int { get }
    
    /// Process a response line from the server
    /// - Parameter response: The response line to process
    /// - Returns: Whether the handler is complete
    func processResponse(_ response: SMTPResponse) -> Bool
    
    /// Create an instance of this handler
    /// - Parameters:
    ///   - commandTag: Optional tag for the command (not commonly used in SMTP but included for consistency)
    ///   - promise: The promise to fulfill when the command completes
    ///   - timeoutSeconds: The timeout in seconds for this command
    /// - Returns: A newly created handler instance
    static func createHandler(commandTag: String?, promise: EventLoopPromise<ResultType>, timeoutSeconds: Int) -> Self
}

/// Default implementation of common handler methods
public extension SMTPCommandHandler {
    /// Default implementation for creating a handler without a command tag
    static func createHandler(promise: EventLoopPromise<ResultType>, timeoutSeconds: Int = 30) -> Self {
        return createHandler(commandTag: nil, promise: promise, timeoutSeconds: timeoutSeconds)
    }
} 