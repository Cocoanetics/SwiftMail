import Foundation
import NIOIMAP
import NIO

/// Command to list all available mailboxes
struct ListCommand: IMAPCommand {
    typealias ResultType = [Mailbox.Info]
    typealias HandlerType = ListCommandHandler
    
    let timeoutSeconds: Int = 30
    
    // Return options for the LIST command
    private let returnOptions: [ReturnOption]
    
    var handlerType: HandlerType.Type {
        return ListCommandHandler.self
    }
    
    /// Initialize a new LIST command
    /// - Parameter returnOptions: Optional list of return options for the LIST command (e.g. SPECIAL-USE)
    init(returnOptions: [ReturnOption] = []) {
        self.returnOptions = returnOptions
    }
    
    func toTaggedCommand(tag: String) -> TaggedCommand {
        // Standard LIST parameters
        let reference = MailboxName(ByteBuffer(string: ""))
        let pattern = MailboxPatterns.pattern([ByteBuffer(string: "*")])
        
        // Use return options if provided
        if !returnOptions.isEmpty {
            return TaggedCommand(tag: tag, command: .list(nil, reference: reference, pattern, returnOptions))
        } else {
            // Standard LIST command without return options
            return TaggedCommand(tag: tag, command: .list(nil, reference: reference, pattern))
        }
    }
}
