import Foundation
import NIOCore
import Logging

/**
 Handler for SMTP QUIT command responses
 */
public final class QuitHandler: BaseSMTPHandler<Bool> {
    
    /**
     Process a response from the server to the QUIT command
     - Parameter response: The response to process
     - Returns: Whether the handler is complete
     */
    override public func processResponse(_ response: SMTPResponse) -> Bool {
        // For QUIT command, any response is considered successful since we're going to close the connection anyway
        // But we should log the response for debugging purposes
        logger.debug("Server response to QUIT: \(response.code) \(response.message)")
        
        // 2xx responses are considered successful
        if response.code >= 200 && response.code < 300 {
            logger.debug("QUIT command successful")
            promise.succeed(true)
        } else {
            // Even non-2xx responses are logged but we still succeed the promise
            // since we'll be closing the connection anyway
            logger.warning("Unexpected response to QUIT: \(response.code) \(response.message)")
            promise.succeed(false)
        }
        
        return true // Always complete after a single response
    }
} 