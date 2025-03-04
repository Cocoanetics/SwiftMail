import Foundation
import NIOCore
import Logging

/// Handler for processing the initial greeting from the SMTP server
public class GreetingHandler: BaseSMTPHandler<SMTPGreeting> {
    /// Handle a successful response by parsing the greeting
    override public func handleSuccess(response: SMTPResponse) {
        // Create a greeting object from the response
        let greeting = SMTPGreeting(code: response.code, message: response.message)
        promise.succeed(greeting)
    }
}

/// Structure representing an SMTP server greeting
public struct SMTPGreeting {
    /// The response code (usually 220)
    public let code: Int
    
    /// The greeting message from the server
    public let message: String
    
    /// Whether the server advertises ESMTP support in the greeting
    public var supportsESMTP: Bool {
        return message.contains("ESMTP")
    }
} 