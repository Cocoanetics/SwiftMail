import Foundation
import NIOCore
import Logging

/// Handler for SMTP PLAIN authentication
class PlainAuthHandler: BaseSMTPHandler<AuthResult>, @unchecked Sendable {
    /// Process a response line from the server
    /// - Parameter response: The response line to process
    /// - Returns: Whether the handler is complete
	override func processResponse(_ response: SMTPResponse) -> Bool {
        // For PLAIN auth, we should get a success response immediately
        if response.code >= 200 && response.code < 300 {
            // Success response
            promise.succeed(AuthResult(method: AuthMethod.plain, success: true))
            return true
        } else if response.code >= 400 {
            // Error response
            promise.succeed(AuthResult(method: AuthMethod.plain, success: false, errorMessage: response.message))
            return true
        }
        
        return false // Not yet complete
    }
} 
