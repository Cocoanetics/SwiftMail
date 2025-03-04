import Foundation
import NIOCore
import Logging

/**
 Handler for the MAIL FROM command response
 */
public final class MailFromHandler: BaseSMTPHandler<Bool> {
    
    /**
     Process a response from the server
     - Parameter response: The response to process
     - Returns: Whether the handler is complete
     */
    override public func processResponse(_ response: SMTPResponse) -> Bool {
        logger.debug("Received MAIL FROM response: \(response.code) \(response.message)")
        
        // 2xx responses are considered successful
        if response.code >= 200 && response.code < 300 {
            logger.info("Sender accepted")
            promise.succeed(true)
        } else {
            // Any other response is considered a failure
            logger.warning("Sender rejected: \(response.code) \(response.message)")
            promise.succeed(false)
        }
        
        return true // Always complete after a single response
    }
} 