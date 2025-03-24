// MoveCommand.swift
// Commands related to moving messages in IMAP

import Foundation
import NIO
import NIOIMAP

/// Command for moving messages from one mailbox to another
public struct MoveCommand<T: MessageIdentifier>: IMAPCommand {
    public typealias ResultType = Void
    public typealias HandlerType = MoveHandler
    
    /// The set of message identifiers to move
    public let identifierSet: MessageIdentifierSet<T>
    
    /// The destination mailbox name
    public let destinationMailbox: String
    
    /// The handler type for processing this command
    public var handlerType: HandlerType.Type { MoveHandler.self }
    
    /// Initialize a new move command
    /// - Parameters:
    ///   - identifierSet: The set of message identifiers to move
    ///   - destinationMailbox: The destination mailbox name
    public init(identifierSet: MessageIdentifierSet<T>, destinationMailbox: String) {
        self.identifierSet = identifierSet
        self.destinationMailbox = destinationMailbox
    }
    
    /// Validate the command before execution
    public func validate() throws {
        guard !identifierSet.isEmpty else {
            throw IMAPError.emptyIdentifierSet
        }
    }
    
    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
    public func toTaggedCommand(tag: String) -> TaggedCommand {
        let mailbox = MailboxName(ByteBuffer(string: destinationMailbox))
        
        if T.self == UID.self {
            return TaggedCommand(tag: tag, command: .uidMove(.set(identifierSet.toNIOSet()), mailbox))
        } else {
            return TaggedCommand(tag: tag, command: .move(.set(identifierSet.toNIOSet()), mailbox))
        }
    }
} 
