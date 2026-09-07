import Foundation
import NIOCore
import Logging

/**
 Handler for the RCPT TO command response
 */
final class RcptToHandler: BaseSMTPHandler<SMTPResponse>, @unchecked Sendable {

    /**
     Process a response from the server
     - Parameter response: The response to process
     - Returns: Whether the handler is complete
     */
    override func processResponse(_ response: SMTPResponse) -> Bool {

        // 2xx responses are considered successful (250, or 251 "will forward")
        if response.code >= 200 && response.code < 300 {
            promise.succeed(response)
        } else {
            // Any other reply rejects the recipient; fail so the transaction
            // aborts instead of silently skipping the recipient.
            promise.fail(SMTPError.unexpectedResponse(response))
        }

        return true // Always complete after a single response
    }
}
