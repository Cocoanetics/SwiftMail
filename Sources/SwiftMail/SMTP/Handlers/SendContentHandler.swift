import Foundation
import NIOCore
import Logging

/**
 Handler for the email content response
 */
final class SendContentHandler: BaseSMTPHandler<SMTPResponse>, @unchecked Sendable {

    /**
     Process a response from the server
     - Parameter response: The response to process
     - Returns: Whether the handler is complete
     */
    override func processResponse(_ response: SMTPResponse) -> Bool {

        // 2xx responses are considered successful; the accepted reply is
        // surfaced to the caller (it often carries the server's queue ID).
        if response.code >= 200 && response.code < 300 {
            promise.succeed(response)
        } else {
            // Any other response is considered a failure
            promise.fail(SMTPError.unexpectedResponse(response))
        }

        return true // Always complete after a single response
    }
}
