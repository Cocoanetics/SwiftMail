import Foundation
import NIOCore
import Logging

/**
 Handler for the email content response
 */
public final class SendContentHandler: BaseSMTPHandler<Bool> {
    
    /**
     Process a response from the server
     - Parameter response: The response to process
     - Returns: Whether the handler is complete
     */
    override public func processResponse(_ response: SMTPResponse) -> Bool {
        
        // 2xx responses are considered successful
        if response.code >= 200 && response.code < 300 {
            promise.succeed(true)
        } else {
            // Any other response is considered a failure
            promise.succeed(false)
        }
        
        return true // Always complete after a single response
    }
} 
