import Foundation
import NIOIMAP
import NIO

/// Command to list all available mailboxes
struct ListCommand: IMAPCommand {
    typealias ResultType = [Mailbox.Info]
    typealias HandlerType = ListCommandHandler
    
    let timeoutSeconds: Int = 30
    
    var handlerType: HandlerType.Type {
        return ListCommandHandler.self
    }
    
    func validate() throws {
        // No validation needed for LIST command
    }
    
    func toTaggedCommand(tag: String) -> TaggedCommand {
        // LIST "" "*" - List all mailboxes
        let reference = MailboxName(ByteBuffer(string: ""))
        let pattern = MailboxPatterns.pattern([ByteBuffer(string: "*")])
        return TaggedCommand(tag: tag, command: .list(nil, reference: reference, pattern))
    }
}
