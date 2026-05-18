import Foundation
import NIO
import NIOIMAPCore

/** Command to delete an existing mailbox. */
struct DeleteMailboxCommand: IMAPTaggedCommand {
    typealias ResultType = Void
    typealias HandlerType = DeleteMailboxHandler

    let mailboxName: String

    init(mailboxName: String) {
        self.mailboxName = mailboxName
    }

    func validate() throws {
        guard !mailboxName.isEmpty else {
            throw IMAPError.invalidArgument("Mailbox name must not be empty")
        }
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        let mailbox = MailboxName(ByteBuffer(string: mailboxName))
        return TaggedCommand(tag: tag, command: .delete(mailbox))
    }
}
