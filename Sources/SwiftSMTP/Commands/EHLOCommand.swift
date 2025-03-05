import Foundation
import NIOCore

/**
 Command to send EHLO and retrieve server capabilities
 */
public struct EHLOCommand: SMTPCommand {
    /// The result type is the raw response text
    public typealias ResultType = String
    
    /// The handler type that will process responses for this command
    public typealias HandlerType = EHLOHandler
    
    /// Timeout in seconds for EHLO command (typically quick to respond)
    public let timeoutSeconds: Int = 30
    
    /// The hostname to use for the EHLO command
    private let hostname: String
    
    /// Initialize a new EHLO command
    /// - Parameter hostname: The hostname to use for the EHLO command
    public init(hostname: String) {
        self.hostname = hostname
    }
    
    /// Convert the command to a string that can be sent to the server
    public func toCommandString() -> String {
        return "EHLO \(hostname)"
    }
    
    /// Validate the command
    public func validate() throws {
        // No validation needed for EHLO
    }
} 