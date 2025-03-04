import Foundation
import NIOCore

/**
 Command to initiate sending email data
 */
public struct DataCommand: SMTPCommand {
    /// The result type is a simple success Boolean
    public typealias ResultType = Bool
    
    /// The handler type that will process responses for this command
    public typealias HandlerType = DataHandler
    
    /**
     Initialize a new DATA command
     */
    public init() {
        // No parameters needed for DATA command
    }
    
    /**
     Convert the command to a string that can be sent to the server
     */
    public func toCommandString() -> String {
        return "DATA"
    }
    
    /**
     Validation is not required for DATA command
     */
    public func validate() throws {
        // No validation needed for DATA command
    }
} 