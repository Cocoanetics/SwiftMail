import Foundation
import NIO
import NIOIMAP

/// Command to select a mailbox in read-only mode.
struct ExamineMailboxCommand: IMAPTaggedCommand {
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
        TaggedCommand(
            tag: tag,
            command: .examine(MailboxName(ByteBuffer(string: mailboxName)))
        )
    }
}
