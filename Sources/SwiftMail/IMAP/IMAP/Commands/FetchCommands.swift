// FetchCommands.swift
// Commands related to fetching data from IMAP server

import Foundation
import NIO
import NIOIMAP

/// Command for fetching message headers
struct FetchMessageInfoCommand<T: MessageIdentifier>: IMAPCommand {
	typealias ResultType = [MessageInfo]
	typealias HandlerType = FetchMessageInfoHandler
    
    /// The set of message identifiers to fetch
	let identifierSet: MessageIdentifierSet<T>
    
    /// Optional limit on the number of headers to return
	let limit: Int?
    
    /// Custom timeout for this operation
	let timeoutSeconds = 10
    
    /// Initialize a new fetch headers command
    /// - Parameters:
    ///   - identifierSet: The set of message identifiers to fetch
    ///   - limit: Optional limit on the number of headers to return
	init(identifierSet: MessageIdentifierSet<T>, limit: Int? = nil) {
        self.identifierSet = identifierSet
        self.limit = limit
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
        let attributes: [FetchAttribute] = [
            .uid,
            .envelope,
            .bodyStructure(extensions: true),
            .bodySection(peek: true, .header, nil),
            .flags
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
 struct FetchMessagePartCommand<T: MessageIdentifier>: IMAPCommand {
	typealias ResultType = Data
	typealias HandlerType = FetchPartHandler
    
    /// The message identifier to fetch
	let identifier: T
    
    /// The section path to fetch (e.g., [1], [1, 1], [2], etc.)
	let section: Section
    
    /// Custom timeout for this operation
	var timeoutSeconds: Int { return 10 }
    
    /// Initialize a new fetch message part command
    /// - Parameters:
    ///   - identifier: The message identifier to fetch
    ///   - sectionPath: The section path to fetch as an array of integers
	 init(identifier: T, section: Section) {
        self.identifier = identifier
        self.section = section
    }
    
    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
	func toTaggedCommand(tag: String) -> TaggedCommand {
        let set = MessageIdentifierSet<T>(identifier)
        
        // Create the section path directly from the array
		let part = SectionSpecifier.Part(section.components)
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
 struct FetchStructureCommand<T: MessageIdentifier>: IMAPCommand {
    typealias ResultType = [MessagePart]
    typealias HandlerType = FetchStructureHandler
    
    /// The message identifier to fetch
    let identifier: T
    
    /// Custom timeout for this operation
    var timeoutSeconds: Int { return 10 }
    
    /// Initialize a new fetch structure command
    /// - Parameter identifier: The message identifier to fetch
    init(identifier: T) {
        self.identifier = identifier
    }
    
    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
    func toTaggedCommand(tag: String) -> TaggedCommand {
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
