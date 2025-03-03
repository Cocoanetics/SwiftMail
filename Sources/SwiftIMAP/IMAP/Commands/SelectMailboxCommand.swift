import Foundation
import NIOIMAP
import NIOIMAPCore
import NIO
import os.log

/// Command to select a mailbox
struct SelectMailboxCommand: IMAPCommand {
    typealias ResultType = Mailbox.Status
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
    
    /// Create a handler for this command
    /// - Parameters:
    ///   - commandTag: The tag for this command
    ///   - promise: The promise to fulfill when the command completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    /// - Returns: A handler for this command
    func createHandler(commandTag: String, promise: EventLoopPromise<Mailbox.Status>, timeoutSeconds: Int, logger: Logger) -> SelectHandler {
        return SelectHandler.createHandler(
            commandTag: commandTag,
            promise: promise,
            timeoutSeconds: timeoutSeconds,
            logger: logger
        )
    }
} 