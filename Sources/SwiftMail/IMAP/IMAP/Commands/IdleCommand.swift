import Foundation
import NIOIMAP

/// Command to start an IMAP IDLE session.
struct IdleCommand: IMAPTaggedCommand {
    typealias ResultType = Void
    typealias HandlerType = IdleHandler

    func toTaggedCommand(tag: String) -> TaggedCommand {
        TaggedCommand(tag: tag, command: .idleStart)
    }
}
