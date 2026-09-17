import NIOIMAP
import NIOIMAPCore

/// Enables connection-local IMAP extensions advertised by the server.
struct EnableCommand: IMAPTaggedCommand {
    typealias ResultType = [Capability]
    typealias HandlerType = EnableHandler

    let capabilities: [Capability]

    func validate() throws {
        guard !capabilities.isEmpty else {
            throw IMAPError.invalidArgument("At least one capability must be requested")
        }
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        TaggedCommand(tag: tag, command: .enable(capabilities))
    }
}
