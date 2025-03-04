import Foundation
import NIOCore
import Logging

/**
 Handler for the STARTTLS command response
 */
public final class StartTLSHandler: BaseSMTPHandler<Bool> {
    
    /**
     Process a response from the server
     - Parameter response: The response to process
     - Returns: Whether the handler is complete
     */
    override public func processResponse(_ response: SMTPResponse) -> Bool {
        logger.debug("Received STARTTLS response: \(response.code) \(response.message)")
        
        // 2xx responses are considered successful
        if response.code >= 200 && response.code < 300 {
            logger.info("STARTTLS command accepted")
            promise.succeed(true)
        } else {
            // Any other response is considered a failure
            logger.warning("STARTTLS command rejected: \(response.code) \(response.message)")
            promise.succeed(false)
        }
        
        return true // Always complete after a single response
    }
} 