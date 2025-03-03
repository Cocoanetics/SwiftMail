import Foundation
import NIOIMAP
import NIOIMAPCore
import NIO
import os.log

/// Command to select a mailbox
struct SelectMailboxCommand: IMAPCommand {
    typealias ResultType = MailboxStatus
    typealias HandlerType = SelectHandler
    
    let mailboxName: String
    let timeoutSeconds: Int = 30
    
    var handlerType: HandlerType.Type {
        return SelectHandler.self
    }
    
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