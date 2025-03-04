import Foundation
import NIOCore

/**
 Command to initiate TLS/SSL encryption on the connection
 */
public struct StartTLSCommand: SMTPCommand {
    /// The result type is a simple success Boolean
    public typealias ResultType = Bool
    
    /// The handler type that will process responses for this command
    public typealias HandlerType = StartTLSHandler
    
    /**
     Initialize a new STARTTLS command
     */
    public init() {
        // No parameters needed for STARTTLS
    }
    
    /**
     Convert the command to a string that can be sent to the server
     */
    public func toCommandString() -> String {
        return "STARTTLS"
    }
    
    /**
     Validation is not required for STARTTLS command
     */
    public func validate() throws {
        // No validation needed for STARTTLS command
    }
} 
