import Foundation
import NIOIMAP
import NIO

/// Command to list all available mailboxes
struct ListCommand: IMAPTaggedCommand {
    typealias ResultType = [Mailbox.Info]
    typealias HandlerType = ListCommandHandler
    
    let timeoutSeconds: Int = 30
    
    // Wildcard to use when listing mailboxes ("*" by default)
    private let wildcard: String

    // Return options for the LIST command
    private let returnOptions: [ReturnOption]
    
    /// Initialize a new LIST command
    /// - Parameters:
    ///   - wildcard: The wildcard pattern used when listing mailboxes. Defaults to "*".
    ///   - returnOptions: Optional list of return options for the LIST command (e.g. SPECIAL-USE)
    init(wildcard: String = "*", returnOptions: [ReturnOption] = []) {
        self.wildcard = wildcard
        self.returnOptions = returnOptions
    }
    
    func toTaggedCommand(tag: String) -> TaggedCommand {
        // Standard LIST parameters
        let reference = MailboxName(ByteBuffer(string: ""))
        let mailbox = MailboxPatterns.mailbox(ByteBuffer(string: wildcard))
        
        // Use return options if provided
        if !returnOptions.isEmpty {
            return TaggedCommand(tag: tag, command: .list(nil, reference: reference, mailbox, returnOptions))
        } else {
            // Standard LIST command without return options
            return TaggedCommand(tag: tag, command: .list(nil, reference: reference, mailbox))
        }
    }
}
