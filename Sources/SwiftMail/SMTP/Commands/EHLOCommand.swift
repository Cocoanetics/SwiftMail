import Foundation
import NIOCore

/**
 Command to send EHLO and retrieve server capabilities
 */
struct EHLOCommand: SMTPCommand {
    /// The result type is the raw response text
    typealias ResultType = String
    
    /// The handler type that will process responses for this command
    typealias HandlerType = EHLOHandler
    
    /// Timeout in seconds for EHLO command (typically quick to respond)
    let timeoutSeconds: Int = 30
    
    /// The hostname to use for the EHLO command
    let hostname: String
    
    /// Initialize a new EHLO command
    /// - Parameter hostname: The hostname to use for the EHLO command
   init(hostname: String) {
        self.hostname = hostname
    }
    
    /// Convert the command to a string that can be sent to the server
    func toCommandString() -> String {
        return "EHLO \(hostname)"
    }
} 
