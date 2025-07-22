import Foundation
import NIOIMAP
import OrderedCollections

/// Command for IMAP ID.
struct IDCommand: IMAPCommand {
    typealias ResultType = IDResponse
    typealias HandlerType = IDHandler

    /// Client identification parameters.
    let parameters: OrderedDictionary<String, String?>

    init(parameters: OrderedDictionary<String, String?> = [:]) {
        self.parameters = parameters
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        TaggedCommand(tag: tag, command: .id(parameters))
    }
}
