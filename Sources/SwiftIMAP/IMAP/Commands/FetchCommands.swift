// FetchCommands.swift
// Commands related to fetching data from IMAP server

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

/// Command for fetching message headers
public struct FetchHeadersCommand<T: MessageIdentifier>: IMAPCommand {
    public typealias ResultType = [EmailHeader]
    public typealias HandlerType = FetchHeadersHandler
    
    /// The set of message identifiers to fetch
    public let identifierSet: MessageIdentifierSet<T>
    
    /// Optional limit on the number of headers to return
    public let limit: Int?
    
    /// The handler type for processing this command
    public var handlerType: HandlerType.Type { FetchHeadersHandler.self }
    
    /// Custom timeout for this operation
    public var timeoutSeconds: Int { return 10 }
    
    /// Initialize a new fetch headers command
    /// - Parameters:
    ///   - identifierSet: The set of message identifiers to fetch
    ///   - limit: Optional limit on the number of headers to return
    public init(identifierSet: MessageIdentifierSet<T>, limit: Int? = nil) {
        self.identifierSet = identifierSet
        self.limit = limit
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
        let attributes: [FetchAttribute] = [
            .uid,
            .envelope,
            .bodyStructure(extensions: false),
            .bodySection(peek: true, .header, nil)
        ]
        
        if T.self == UID.self {
            return TaggedCommand(tag: tag, command: .uidFetch(
                .set(identifierSet.toNIOSet()), attributes, []
            ))
        } else {
            return TaggedCommand(tag: tag, command: .fetch(
                .set(identifierSet.toNIOSet()), attributes, []
            ))
        }
    }
}

/// Command for fetching a specific message part
public struct FetchMessagePartCommand<T: MessageIdentifier>: IMAPCommand {
    public typealias ResultType = Data
    public typealias HandlerType = FetchPartHandler
    
    /// The message identifier to fetch
    public let identifier: T
    
    /// The section path to fetch (e.g., [1], [1, 1], [2], etc.)
    public let sectionPath: [Int]
    
    /// The handler type for processing this command
    public var handlerType: HandlerType.Type { FetchPartHandler.self }
    
    /// Custom timeout for this operation
    public var timeoutSeconds: Int { return 10 }
    
    /// Initialize a new fetch message part command
    /// - Parameters:
    ///   - identifier: The message identifier to fetch
    ///   - sectionPath: The section path to fetch as an array of integers
    public init(identifier: T, sectionPath: [Int]) {
        self.identifier = identifier
        self.sectionPath = sectionPath
    }
    
    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
    public func toTaggedCommand(tag: String) -> TaggedCommand {
        let set = MessageIdentifierSet<T>(identifier)
        
        // Create the section path directly from the array
        let part = SectionSpecifier.Part(sectionPath)
        let section = SectionSpecifier(part: part)
        
        let attributes: [FetchAttribute] = [
            .bodySection(peek: true, section, nil)
        ]
        
        if T.self == UID.self {
            return TaggedCommand(tag: tag, command: .uidFetch(
                .set(set.toNIOSet()), attributes, []
            ))
        } else {
            return TaggedCommand(tag: tag, command: .fetch(
                .set(set.toNIOSet()), attributes, []
            ))
        }
    }
}

/// Command for fetching the structure of a message
public struct FetchStructureCommand<T: MessageIdentifier>: IMAPCommand {
    public typealias ResultType = BodyStructure
    public typealias HandlerType = FetchStructureHandler
    
    /// The message identifier to fetch
    public let identifier: T
    
    /// The handler type for processing this command
    public var handlerType: HandlerType.Type { FetchStructureHandler.self }
    
    /// Custom timeout for this operation
    public var timeoutSeconds: Int { return 10 }
    
    /// Initialize a new fetch structure command
    /// - Parameter identifier: The message identifier to fetch
    public init(identifier: T) {
        self.identifier = identifier
    }
    
    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
    public func toTaggedCommand(tag: String) -> TaggedCommand {
        let set = MessageIdentifierSet<T>(identifier)
        
        let attributes: [FetchAttribute] = [
            .bodyStructure(extensions: true)
        ]
        
        if T.self == UID.self {
            return TaggedCommand(tag: tag, command: .uidFetch(
                .set(set.toNIOSet()), attributes, []
            ))
        } else {
            return TaggedCommand(tag: tag, command: .fetch(
                .set(set.toNIOSet()), attributes, []
            ))
        }
    }
} 