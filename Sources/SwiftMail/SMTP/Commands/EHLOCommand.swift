import Foundation
import NIOCore

/**
 Command to send EHLO and retrieve server capabilities
 */
struct EHLOCommand: SMTPCommand {
    /// The result type is the raw response text
    typealias ResultType = String

    /// The handler type that will process responses for this command
    typealias HandlerType = EHLOHandler

    /// Timeout in seconds for EHLO command (typically quick to respond)
    let timeoutSeconds: Int = 30

    /// The client identity to use for the EHLO command
    let clientIdentity: String

    /// Initialize a new EHLO command
    /// - Parameter clientIdentity: The RFC 5321 domain or address literal to use for the EHLO command
    init(clientIdentity: String) {
        self.clientIdentity = clientIdentity
    }

    /// Convert the command to a string that can be sent to the server
    func toCommandString() -> String {
        return "EHLO \(clientIdentity)"
    }

    /// Reject malformed identities before they can alter the SMTP command stream.
    func validate() throws {
        let bytes = clientIdentity.utf8
        guard (1...255).contains(bytes.count),
            bytes.allSatisfy({ (33...126).contains($0) }) else {
            throw SMTPError.commandFailed(
                "EHLO client identity must be 1...255 printable ASCII characters without whitespace"
            )
        }
    }
}
