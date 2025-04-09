import Foundation
import NIOCore
import Logging

/// Handler for processing the initial greeting from the SMTP server
final class SMTPGreetingHandler: BaseSMTPHandler<SMTPGreeting>, @unchecked Sendable {
    /// Handle a successful response by parsing the greeting
    override func handleSuccess(response: SMTPResponse) {
        // Create a greeting object from the response
        let greeting = SMTPGreeting(code: response.code, message: response.message)
        promise.succeed(greeting)
    }
}

/// Structure representing an SMTP server greeting
struct SMTPGreeting {
    /// The response code (usually 220)
	let code: Int
    
    /// The greeting message from the server
	let message: String
    
    /// Whether the server advertises ESMTP support in the greeting
	var supportsESMTP: Bool {
        return message.contains("ESMTP")
    }
} 
