import Foundation
import NIOCore
import Logging

/**
 A protocol representing an SMTP command
 */
public protocol SMTPCommand {
    /// The type of result this command returns
    associatedtype ResultType
    
    /// The type of handler that will process responses for this command
    associatedtype HandlerType: SMTPCommandHandler where HandlerType.ResultType == ResultType
    
    /// Convert this command to a string that can be sent to the SMTP server
    /// This method should be the primary method used to generate the command string
    func toCommandString() -> String
    
    /// Convert this command to a string that can be sent to the SMTP server with a hostname
    /// - Parameter localHostname: The local hostname to use for commands that require it (e.g., EHLO)
    /// - Returns: The command string
    func toString(localHostname: String) -> String
    
    /// Validate that the command is correctly formed
    /// - Throws: An error if the command is invalid
    func validate() throws
	
	/// Custom timeout for this operation
	var timeoutSeconds: Int { get }
}

/// Default implementation for common command behaviors
extension SMTPCommand {
    /// Default validation (no-op, can be overridden by specific commands)
    public func validate() throws {
        // No validation by default
    }
    
    /// Default implementation that calls toString with the hostname
    /// Subclasses should override this for commands that don't need a hostname
    public func toCommandString() -> String {
        fatalError("Must be implemented by subclass - either toCommandString() or toString(localHostname:)")
    }
    
    /// Default implementation throws an error
    /// Only commands that require a hostname should implement this
    public func toString(localHostname: String) -> String {
        return toCommandString()
    }
} 
