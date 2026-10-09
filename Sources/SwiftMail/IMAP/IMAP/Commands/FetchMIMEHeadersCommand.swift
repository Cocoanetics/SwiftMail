// FetchMIMEHeadersCommand.swift
// Command for fetching the MIME headers of several parts of one message

import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

/// Fetches `BODY.PEEK[<section>.MIME]` for several parts of one message in a
/// single FETCH, returning each part's raw MIME header block by section.
///
/// A section the server answers without a header (or does not answer at all)
/// is absent from the result.
struct FetchMIMEHeadersCommand<T: MessageIdentifier>: IMAPTaggedCommand {
    typealias ResultType = [Section: Data]
    typealias HandlerType = FetchMIMEHeadersHandler

    /// The message whose parts are asked for
    let identifier: T

    /// The parts whose MIME headers are fetched
    let sections: [Section]

    /// Custom timeout for this operation
    var timeoutSeconds: Int { return 30 }

    init(identifier: T, sections: [Section]) {
        self.identifier = identifier
        self.sections = sections
    }

    func validate() throws {
        guard !sections.isEmpty else {
            throw IMAPError.fetchFailed("No sections to fetch MIME headers for")
        }
    }

    func makeHandler(commandTag: String, promise: EventLoopPromise<[Section: Data]>) -> FetchMIMEHeadersHandler {
        FetchMIMEHeadersHandler(commandTag: commandTag, promise: promise, sections: sections)
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        let set = MessageIdentifierSet<T>(identifier)
        let attributes: [FetchAttribute] = sections.map {
            .bodySection(peek: true, Self.specifier(for: $0), nil)
        }

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

    /// The `<section>.MIME` specifier for a part.
    static func specifier(for section: Section) -> SectionSpecifier {
        SectionSpecifier(part: .init(section.components), kind: .MIMEHeader)
    }
}
