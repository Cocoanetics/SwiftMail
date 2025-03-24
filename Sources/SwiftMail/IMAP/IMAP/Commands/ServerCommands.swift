// ServerCommands.swift
// Commands related to IMAP server operations

import Foundation
import NIO
import NIOIMAP

/// Command for retrieving server capabilities
struct CapabilityCommand: IMAPCommand {
	typealias ResultType = [Capability]
	typealias HandlerType = CapabilityHandler
    
    /// The handler type for processing this command
    var handlerType: HandlerType.Type { CapabilityHandler.self }
    
    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
    func toTaggedCommand(tag: String) -> TaggedCommand {
        return TaggedCommand(tag: tag, command: .capability)
    }
}

/// Command for copying messages from one mailbox to another
struct CopyCommand<T: MessageIdentifier>: IMAPCommand {
    typealias ResultType = Void
    typealias HandlerType = CopyHandler
    
    /// The set of message identifiers to copy
    let identifierSet: MessageIdentifierSet<T>
    
    /// The destination mailbox name
    let destinationMailbox: String
    
    /// The handler type for processing this command
    var handlerType: HandlerType.Type { CopyHandler.self }
    
    /// Initialize a new copy command
    /// - Parameters:
    ///   - identifierSet: The set of message identifiers to copy
    ///   - destinationMailbox: The destination mailbox name
    init(identifierSet: MessageIdentifierSet<T>, destinationMailbox: String) {
        self.identifierSet = identifierSet
        self.destinationMailbox = destinationMailbox
    }
    
    /// Validate the command before execution
    func validate() throws {
        guard !identifierSet.isEmpty else {
            throw IMAPError.emptyIdentifierSet
        }
    }
    
    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
    func toTaggedCommand(tag: String) -> TaggedCommand {
        let mailbox = MailboxName(ByteBuffer(string: destinationMailbox))
        
        if T.self == UID.self {
            return TaggedCommand(tag: tag, command: .uidCopy(.set(identifierSet.toNIOSet()), mailbox))
        } else {
            return TaggedCommand(tag: tag, command: .copy(.set(identifierSet.toNIOSet()), mailbox))
        }
    }
}

/// Command for storing flags on messages
struct StoreCommand<T: MessageIdentifier>: IMAPCommand {
    typealias ResultType = Void
    typealias HandlerType = StoreHandler
    
    /// The set of message identifiers to update
    let identifierSet: MessageIdentifierSet<T>
    
    /// The data to store
    let data: StoreData
    
    /// The handler type for processing this command
    var handlerType: HandlerType.Type { StoreHandler.self }
    
    /// Initialize a new store command
    /// - Parameters:
    ///   - identifierSet: The set of message identifiers to update
    ///   - data: The data to store
    init(identifierSet: MessageIdentifierSet<T>, data: StoreData) {
        self.identifierSet = identifierSet
        self.data = data
    }
    
    /// Validate the command before execution
    func validate() throws {
        guard !identifierSet.isEmpty else {
            throw IMAPError.emptyIdentifierSet
        }
    }
    
    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
    func toTaggedCommand(tag: String) -> TaggedCommand {
        if T.self == UID.self {
            return TaggedCommand(tag: tag, command: .uidStore(.set(identifierSet.toNIOSet()), [], data.toNIO()))
        } else {
            return TaggedCommand(tag: tag, command: .store(.set(identifierSet.toNIOSet()), [], data.toNIO()))
        }
    }
}

/// Command for expunging deleted messages
struct ExpungeCommand: IMAPCommand {
    typealias ResultType = Void
    typealias HandlerType = ExpungeHandler
    
    /// The handler type for processing this command
	var handlerType: HandlerType.Type { ExpungeHandler.self }
    
    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
    func toTaggedCommand(tag: String) -> TaggedCommand {
        return TaggedCommand(tag: tag, command: .expunge)
    }
} 
