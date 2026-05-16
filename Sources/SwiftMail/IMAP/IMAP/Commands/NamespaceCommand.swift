import Foundation
import NIO
import NIOIMAP

/// Command to fetch namespace information
struct NamespaceCommand: IMAPTaggedCommand {
    typealias ResultType = NamespaceResponse
    typealias HandlerType = NamespaceHandler

    func toTaggedCommand(tag: String) -> TaggedCommand {
        TaggedCommand(tag: tag, command: .namespace)
    }
}
