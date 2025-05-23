import Foundation
import NIOIMAP

/// Command to start the IMAP IDLE mode
struct IdleCommand: IMAPCommand {
    typealias ResultType = Void
    typealias HandlerType = IdleHandler

    func toTaggedCommand(tag: String) -> TaggedCommand {
        TaggedCommand(tag: tag, command: .idleStart)
    }
}
