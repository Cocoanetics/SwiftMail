import Foundation
import NIOIMAP

/// Command for IMAP NOOP
struct NoopCommand: IMAPCommand {
    typealias ResultType = [IMAPServerEvent]
    typealias HandlerType = NoopHandler

    func toTaggedCommand(tag: String) -> TaggedCommand {
        TaggedCommand(tag: tag, command: .noop)
    }
}
