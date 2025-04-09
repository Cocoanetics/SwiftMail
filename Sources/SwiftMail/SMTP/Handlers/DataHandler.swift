import Foundation
import NIOCore
import Logging

/**
 Handler for the DATA command response
 */
final class DataHandler: BaseSMTPHandler<Bool>, @unchecked Sendable {
    
    /**
     Process a response from the server
     - Parameter response: The response to process
     - Returns: Whether the handler is complete
     */
    override func processResponse(_ response: SMTPResponse) -> Bool {
        
        // 3xx responses are considered successful for DATA command (server is ready for content)
        if response.code >= 300 && response.code < 400 {
            promise.succeed(true)
        } else {
            // Any other response is considered a failure
            promise.succeed(false)
        }
        
        return true // Always complete after a single response
    }
} 
