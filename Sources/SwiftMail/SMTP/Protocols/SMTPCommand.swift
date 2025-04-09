import Foundation
import NIOCore
import Logging

/**
 A protocol representing an SMTP command
 */
protocol SMTPCommand where ResultType: Sendable {
    /// The type of result this command returns
    associatedtype ResultType
    
    /// The type of handler that will process responses for this command
    associatedtype HandlerType: SMTPCommandHandler where HandlerType.ResultType == ResultType
    
    /// Convert this command to a string that can be sent to the SMTP server
    /// This method should be the primary method used to generate the command string
    func toCommandString() -> String
    
    /// Validate that the command is correctly formed
    /// - Throws: An error if the command is invalid
    func validate() throws
	
	/// Custom timeout for this operation
	var timeoutSeconds: Int { get }
}

/// Default implementation for common command behaviors
extension SMTPCommand {
    /// Default validation (no-op, can be overridden by specific commands)
    func validate() throws {
        // No validation by default
    }
    
    /// Default implementation that calls toString with the hostname
    /// Subclasses should override this for commands that don't need a hostname
    func toCommandString() -> String {
        fatalError("Must be implemented by subclass - either toCommandString() or toString(localHostname:)")
    }
}
