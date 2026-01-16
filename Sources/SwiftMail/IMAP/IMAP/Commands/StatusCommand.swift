import Foundation
import NIO
import NIOIMAP

/// Command to get status information about a mailbox without selecting it
struct StatusCommand: IMAPTaggedCommand {
    typealias ResultType = NIOIMAPCore.MailboxStatus
    typealias HandlerType = StatusHandler
    
    let mailboxName: String
    let attributes: [NIOIMAPCore.MailboxAttribute]
    let timeoutSeconds: Int = 30
    
    init(mailboxName: String, attributes: [NIOIMAPCore.MailboxAttribute]) {
        self.mailboxName = mailboxName
        self.attributes = attributes
    }
    
    func validate() throws {
        guard !mailboxName.isEmpty else {
            throw IMAPError.invalidArgument("Mailbox name cannot be empty")
        }
        guard !attributes.isEmpty else {
            throw IMAPError.invalidArgument("At least one attribute must be requested")
        }
    }
    
    func toTaggedCommand(tag: String) -> TaggedCommand {
        return TaggedCommand(tag: tag, command: .status(
            MailboxName(ByteBuffer(string: mailboxName)),
            attributes
        ))
    }
}
