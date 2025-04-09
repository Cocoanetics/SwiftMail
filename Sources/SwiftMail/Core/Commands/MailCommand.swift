// MailCommand.swift
// Common command protocol for mail protocols (IMAP, SMTP, etc.)

import Foundation
import NIO

/// A generic protocol for mail commands across different protocols
protocol MailCommand where ResultType: Sendable {
    /// The result type this command produces
    associatedtype ResultType
    
    /// The handler type used to process this command
    associatedtype HandlerType: MailCommandHandler where HandlerType.ResultType == ResultType
    
    /// Default timeout for this command type in seconds
    var timeoutSeconds: Int { get }
    
    /// Check if the command is valid before execution
    func validate() throws
}

/// Default implementation for common command behaviors
extension MailCommand {
    var timeoutSeconds: Int { return 10 }
    
    func validate() throws {
        // Default implementation does no validation
    }
}

/// A marker protocol for command handlers
protocol MailCommandHandler: Sendable where ResultType: Sendable {
    /// The result type for this handler
    associatedtype ResultType
    
    /// Optional tag for the command (used in IMAP, rarely in SMTP, but included for consistency)
    var commandTag: String? { get }
    
    /// The promise that will be fulfilled when the command completes
    var promise: EventLoopPromise<ResultType> { get }
    
    /// Generic process response method that can handle any response type
    /// This method should be implemented by all handler implementations and is meant to be
    /// called with a response type that may need to be cast to the specific type the handler expects.
    /// - Parameter response: The response to process (any type)
    /// - Returns: Whether the handler is complete
    func processResponse<T>(_ response: T) -> Bool
    
    /// Required initializer for creating handler instances
    /// - Parameters:
    ///   - commandTag: Optional tag for the command
    ///   - promise: The promise to fulfill when the command completes
    init(commandTag: String?, promise: EventLoopPromise<ResultType>)
} 
