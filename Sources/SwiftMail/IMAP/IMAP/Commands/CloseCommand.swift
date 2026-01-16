import Foundation
import NIOIMAPCore

/** Command to close the currently selected mailbox */
struct CloseCommand: IMAPTaggedCommand {
	typealias ResultType = Void
	typealias HandlerType = CloseHandler
    
    func toTaggedCommand(tag: String) -> TaggedCommand {
        TaggedCommand(tag: tag, command: .close)
    }
} 
