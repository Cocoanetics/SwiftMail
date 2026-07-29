import Foundation
import NIOCore

/**
 Command to abort the current mail transaction (RFC 5321 §4.1.1.5)

 RSET clears any sender, recipients, and mail data accumulated in the current
 transaction and returns the session to the state after EHLO. Servers MUST
 reply `250 OK`, even when no transaction is in progress.
 */
struct RsetCommand: SMTPCommand {
    /// The result is the server's accepting 2xx reply; anything else fails the command
    typealias ResultType = SMTPResponse

    /// The handler type that will process responses for this command
    typealias HandlerType = RsetHandler

    /// Default timeout in seconds
    let timeoutSeconds: Int = 10

    /**
     Convert the command to a string that can be sent to the server
     */
    func toCommandString() -> String {
        return "RSET"
    }
}
