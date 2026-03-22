import Foundation
import NIOIMAP

/// Command for upgrading an existing IMAP connection to TLS.
struct STARTTLSCommand: IMAPTaggedCommand {
    typealias ResultType = Bool
    typealias HandlerType = STARTTLSHandler

    func toTaggedCommand(tag: String) -> TaggedCommand {
        TaggedCommand(tag: tag, command: .startTLS)
    }
}
