import Foundation
import NIOCore
import Logging

/**
 Handler for the DATA command response
 */
final class DataHandler: BaseSMTPHandler<SMTPResponse>, @unchecked Sendable {

    /**
     Process a response from the server
     - Parameter response: The response to process
     - Returns: Whether the handler is complete
     */
    override func processResponse(_ response: SMTPResponse) -> Bool {

        // RFC 5321 §3.3: message data MUST NOT be sent unless the server
        // replied exactly 354. Any other reply — including other 3xx codes —
        // fails the command so no content is ever transmitted after it.
        if response.code == 354 {
            promise.succeed(response)
        } else {
            promise.fail(SMTPError.unexpectedResponse(response))
        }

        return true // Always complete after a single response
    }
}
