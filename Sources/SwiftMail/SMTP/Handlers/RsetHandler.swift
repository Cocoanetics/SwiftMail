import Foundation
import NIOCore
import Logging

/**
 Handler for the RSET command response
 */
final class RsetHandler: BaseSMTPHandler<SMTPResponse>, @unchecked Sendable {

    /**
     Process a response from the server
     - Parameter response: The response to process
     - Returns: Whether the handler is complete
     */
    override func processResponse(_ response: SMTPResponse) -> Bool {

        // RFC 5321 §4.1.1.5 requires a 250 reply; accept any 2xx as success
        if response.code >= 200 && response.code < 300 {
            promise.succeed(response)
        } else {
            // A refused RSET means the session state is unknown
            promise.fail(SMTPError.unexpectedResponse(response))
        }

        return true // Always complete after a single response
    }
}
