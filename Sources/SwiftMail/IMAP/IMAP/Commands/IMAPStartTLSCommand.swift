import Foundation
import NIOIMAP

/// Command for upgrading an existing IMAP connection to TLS.
struct IMAPStartTLSCommand: IMAPTaggedCommand {
    typealias ResultType = Bool
    typealias HandlerType = IMAPStartTLSHandler

    func toTaggedCommand(tag: String) -> TaggedCommand {
        TaggedCommand(tag: tag, command: .startTLS)
    }
}
