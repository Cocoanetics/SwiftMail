import Foundation
import NIO
import NIOIMAP

/// Command to select a mailbox
struct SelectMailboxCommand: IMAPTaggedCommand {
    typealias ResultType = Mailbox.Selection
    typealias HandlerType = SelectHandler
    
    let mailboxName: String
    let timeoutSeconds: Int = 30
    
    init(mailboxName: String) {
        self.mailboxName = mailboxName
    }
    
    func validate() throws {
        guard !mailboxName.isEmpty else {
            throw IMAPError.invalidArgument("Mailbox name cannot be empty")
        }
    }
    
    func toTaggedCommand(tag: String) -> TaggedCommand {
        return TaggedCommand(tag: tag, command: .select(MailboxName(ByteBuffer(string: mailboxName))))
    }
}
