import Foundation
import NIO
import NIOIMAPCore
import OrderedCollections

/** Command to rename an existing mailbox. */
struct RenameMailboxCommand: IMAPTaggedCommand {
    typealias ResultType = Void
    typealias HandlerType = RenameMailboxHandler

    let from: String
    let to: String

    init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    func validate() throws {
        guard !from.isEmpty, !to.isEmpty else {
            throw IMAPError.invalidArgument("Source and destination mailbox names must not be empty")
        }
        guard from != to else {
            throw IMAPError.invalidArgument("Source and destination mailbox names must differ")
        }
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        let source = MailboxName(ByteBuffer(string: from))
        let destination = MailboxName(ByteBuffer(string: to))
        let parameters: OrderedDictionary<String, ParameterValue?> = [:]
        return TaggedCommand(tag: tag, command: .rename(from: source, to: destination, parameters: parameters))
    }
}
