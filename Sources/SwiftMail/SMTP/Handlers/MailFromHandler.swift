import Foundation
import NIOCore
import Logging

/**
 Handler for the MAIL FROM command response
 */
final class MailFromHandler: BaseSMTPHandler<SMTPResponse>, @unchecked Sendable {

    /**
     Process a response from the server
     - Parameter response: The response to process
     - Returns: Whether the handler is complete
     */
    override func processResponse(_ response: SMTPResponse) -> Bool {

        // 2xx responses are considered successful
        if response.code >= 200 && response.code < 300 {
            promise.succeed(response)
        } else {
            // Any other reply rejects the sender; fail so the transaction
            // aborts instead of continuing against a refused MAIL FROM.
            promise.fail(SMTPError.unexpectedResponse(response))
        }

        return true // Always complete after a single response
    }
}
