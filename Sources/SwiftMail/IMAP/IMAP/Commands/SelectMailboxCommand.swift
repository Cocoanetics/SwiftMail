import Foundation
import NIO
import NIOIMAP

/// Command to select a mailbox
public struct SelectMailboxCommand: IMAPCommand {
    public typealias ResultType = Mailbox.Status
    public typealias HandlerType = SelectHandler
    
    public let mailboxName: String
    public let timeoutSeconds: Int = 30
    
    public var handlerType: HandlerType.Type {
        return SelectHandler.self
    }
    
    public init(mailboxName: String) {
        self.mailboxName = mailboxName
    }
    
    public func validate() throws {
        guard !mailboxName.isEmpty else {
            throw IMAPError.invalidArgument("Mailbox name cannot be empty")
        }
    }
    
    public func toTaggedCommand(tag: String) -> TaggedCommand {
        return TaggedCommand(tag: tag, command: .select(MailboxName(ByteBuffer(string: mailboxName))))
    }
}
