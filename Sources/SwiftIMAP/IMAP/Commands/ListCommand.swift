import Foundation
import NIOIMAP
import NIO

/// Command to list all available mailboxes
public struct ListCommand: IMAPCommand {
    public typealias ResultType = [Mailbox.Info]
    public typealias HandlerType = ListCommandHandler
    
    public let timeoutSeconds: Int = 30
    
    public var handlerType: HandlerType.Type {
        return ListCommandHandler.self
    }
    
    public init() {}
    
    public func validate() throws {
        // No validation needed for LIST command
    }
    
    public func toTaggedCommand(tag: String) -> TaggedCommand {
        // LIST "" "*" - List all mailboxes
        let reference = MailboxName(ByteBuffer(string: ""))
        let pattern = MailboxPatterns.pattern([ByteBuffer(string: "*")])
        return TaggedCommand(tag: tag, command: .list(nil, reference: reference, pattern))
    }
}
