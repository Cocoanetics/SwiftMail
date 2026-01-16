import Foundation
import NIOIMAP
import NIO

/// Command to fetch namespace information
struct NamespaceCommand: IMAPTaggedCommand {
    typealias ResultType = Namespace.Response
    typealias HandlerType = NamespaceHandler

    func toTaggedCommand(tag: String) -> TaggedCommand {
        return TaggedCommand(tag: tag, command: .namespace)
    }
}
