import Foundation
import NIOCore
import Logging

/**
 Handler for SMTP QUIT command responses
 */
final class QuitHandler: BaseSMTPHandler<Bool>, @unchecked Sendable {
    
    /**
     Process a response from the server to the QUIT command
     - Parameter response: The response to process
     - Returns: Whether the handler is complete
     */
    override func processResponse(_ response: SMTPResponse) -> Bool {
        // For QUIT command, any response is considered successful since we're going to close the connection anyway
        // But we should log the response for debugging purposes
        
        // 2xx responses are considered successful
        if response.code >= 200 && response.code < 300 {
            promise.succeed(true)
        } else {
            // Even non-2xx responses are logged but we still succeed the promise
            // since we'll be closing the connection anyway
            promise.succeed(false)
        }
        
        return true // Always complete after a single response
    }
} 
