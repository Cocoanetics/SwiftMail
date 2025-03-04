import Foundation
import NIOIMAPCore

/** Command to close the currently selected mailbox */
public struct CloseCommand: IMAPCommand {
    public typealias ResultType = Void
    public typealias HandlerType = CloseHandler
    
    public var handlerType: HandlerType.Type {
        return CloseHandler.self
    }
    
    public init() {}
    
    public func validate() throws {
        // No validation needed for CLOSE command
    }
    
    public func toTaggedCommand(tag: String) -> TaggedCommand {
        TaggedCommand(tag: tag, command: .close)
    }
} 