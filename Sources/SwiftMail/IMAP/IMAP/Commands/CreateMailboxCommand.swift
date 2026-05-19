import Foundation
import NIOIMAPCore
import NIO

/** Command to create a new mailbox */
struct CreateMailboxCommand: IMAPTaggedCommand {
    typealias ResultType = Void
    typealias HandlerType = CreateMailboxHandler

    let mailboxName: String

    func toTaggedCommand(tag: String) -> TaggedCommand {
        let mailbox = MailboxName(ByteBuffer(string: mailboxName))
        return TaggedCommand(tag: tag, command: .create(mailbox, []))
    }
}
