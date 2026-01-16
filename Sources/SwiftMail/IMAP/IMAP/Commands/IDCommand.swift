import Foundation
import NIOIMAP
import OrderedCollections

/// Command for IMAP ID.
struct IDCommand: IMAPTaggedCommand {
    typealias ResultType = Identification
    typealias HandlerType = IDHandler

    /// Client identification parameters.
    let identification: Identification

    init(identification: Identification = Identification()) {
        self.identification = identification
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        TaggedCommand(tag: tag, command: .id(identification.nioParameters))
    }
}
