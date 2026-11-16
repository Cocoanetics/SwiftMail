import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

/// Command to select a mailbox
struct SelectMailboxCommand: IMAPTaggedCommand {
    typealias ResultType = Mailbox.Selection
    typealias HandlerType = SelectHandler

    let mailboxName: String
    /// Sends the RFC 7162 `CONDSTORE` select parameter.
    let condStore: Bool
    let timeoutSeconds: Int = 30

    init(mailboxName: String, condStore: Bool = false) {
        self.mailboxName = mailboxName
        self.condStore = condStore
    }

    func validate() throws {
        guard !mailboxName.isEmpty else {
            throw IMAPError.invalidArgument("Mailbox name cannot be empty")
        }
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        let parameters: [SelectParameter] = condStore ? [.condStore] : []
        return TaggedCommand(tag: tag, command: .select(MailboxName(ByteBuffer(string: mailboxName)), parameters))
    }
}
