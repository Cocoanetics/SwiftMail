// FetchCommands.swift
// Commands related to fetching data from IMAP server

import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

/// Command for fetching message metadata. The exact attributes requested are selected by
/// `options`; pass `headerFields` to request a `BODY.PEEK[HEADER.FIELDS (...)]` section
/// instead of (or in addition to) the full header — useful for newsletter / auto-mail
/// detection without the cost of the full header section.
struct FetchMessageInfoCommand<T: MessageIdentifier>: IMAPTaggedCommand {
    typealias ResultType = [MessageInfo]
    typealias HandlerType = FetchMessageInfoHandler

    /// The set of message identifiers to fetch
    let identifierSet: MessageIdentifierSet<T>

    /// Which attributes to request alongside UID.
    let options: FetchMessageInfoOptions

    /// Optional named header fields to request via `BODY.PEEK[HEADER.FIELDS (...)]`.
    /// Ignored when `options` already contains `.fullHeader` (the full header section
    /// includes everything).
    let headerFields: [String]?

    /// Custom timeout for this operation
    let timeoutSeconds = 10

    /// Initialize a new fetch headers command
    /// - Parameters:
    ///   - identifierSet: The set of message identifiers to fetch
    ///   - options: Which attributes to request. Defaults to `.default`.
    ///   - headerFields: Optional named header fields. See `FetchMessageInfoOptions.newsletterHeaderFields`.
    init(
        identifierSet: MessageIdentifierSet<T>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil
    ) {
        self.identifierSet = identifierSet
        self.options = options
        self.headerFields = headerFields
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
        var attributes: [FetchAttribute] = [.uid]
        if options.contains(.envelope) {
            attributes.append(.envelope)
        }
        if options.contains(.internalDate) {
            attributes.append(.internalDate)
        }
        if options.contains(.flags) {
            attributes.append(.flags)
        }
        if options.contains(.size) {
            attributes.append(.rfc822Size)
        }
        if options.contains(.bodyStructure) {
            attributes.append(.bodyStructure(extensions: true))
        }

        if options.contains(.fullHeader) {
            attributes.append(.bodySection(peek: true, .header, nil))
        } else if let fields = headerFields, !fields.isEmpty {
            let section = SectionSpecifier(part: .init([]), kind: .headerFields(fields))
            attributes.append(.bodySection(peek: true, section, nil))
        }

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
struct FetchMessagePartCommand<T: MessageIdentifier>: IMAPTaggedCommand {
    typealias ResultType = Data
    typealias HandlerType = FetchPartHandler

    /// The message identifier to fetch
    let identifier: T

    /// The section path to fetch (e.g., [1], [1, 1], [2], etc.)
    let section: Section

    /// Custom timeout for this operation
    var timeoutSeconds: Int { return 60 }

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

/// Command for fetching the complete raw message (headers + body)
struct FetchRawMessageCommand<T: MessageIdentifier>: IMAPTaggedCommand {
    typealias ResultType = Data
    typealias HandlerType = FetchPartHandler

    /// The message identifier to fetch
    let identifier: T

    /// Custom timeout for this operation
    var timeoutSeconds: Int { return 10 }

    /// Initialize a new fetch raw message command
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
            .bodySection(peek: true, SectionSpecifier.complete, nil)
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
struct FetchStructureCommand<T: MessageIdentifier>: IMAPTaggedCommand {
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
