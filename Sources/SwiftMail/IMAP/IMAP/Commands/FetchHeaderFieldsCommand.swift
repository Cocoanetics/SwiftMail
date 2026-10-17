// FetchHeaderFieldsCommand.swift
// Command for fetching the raw header lines of named fields for several messages

import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

/// Fetches `BODY.PEEK[HEADER.FIELDS (<fields>)]` for a set of messages in a
/// single FETCH, returning each message's raw header block by identifier.
///
/// The block holds the bytes exactly as the server sent them: every instance
/// of a repeated field, in the server's order, folded and transfer-encoded as
/// in the message. A message the server answers without the section (or does
/// not answer at all) is absent from the result.
struct FetchHeaderFieldsCommand<T: MessageIdentifier>: IMAPTaggedCommand {
    typealias ResultType = [T: Data]
    typealias HandlerType = FetchHeaderFieldsHandler<T>

    /// The most messages one command asks for when the caller sets no chunk size.
    static var defaultChunkSize: Int { 200 }

    /// The deadline for one command when the caller sets none.
    static var defaultTimeoutSeconds: Int { 30 }

    /// The messages whose header fields are asked for
    let identifierSet: MessageIdentifierSet<T>

    /// The header field names to request
    let fields: [String]

    /// The deadline for the server's complete answer to this command
    let timeoutSeconds: Int

    init(identifierSet: MessageIdentifierSet<T>, fields: [String], timeoutSeconds: Int? = nil) {
        self.identifierSet = identifierSet
        self.fields = fields
        self.timeoutSeconds = timeoutSeconds ?? Self.defaultTimeoutSeconds
    }

    /// The commands that fetch `fields` for `identifierSet`, at most
    /// `chunkSize` messages each (``defaultChunkSize`` when `nil`; zero or
    /// less sends one command). A set that ends in `*` is sent whole: it
    /// cannot be split without expanding the open range.
    static func chunks(
        fields: [String],
        identifierSet: MessageIdentifierSet<T>,
        chunkSize: Int?,
        timeoutSeconds: Int?
    ) throws -> [FetchHeaderFieldsCommand<T>] {
        guard !identifierSet.isEmpty else {
            throw IMAPError.emptyIdentifierSet
        }
        let sets = identifierSet.contains(T.latest)
            ? [identifierSet]
            : identifierSet.chunked(size: chunkSize ?? defaultChunkSize)
        return sets.map { FetchHeaderFieldsCommand(identifierSet: $0, fields: fields, timeoutSeconds: timeoutSeconds) }
    }

    func validate() throws {
        guard !identifierSet.isEmpty else {
            throw IMAPError.emptyIdentifierSet
        }
        guard !fields.isEmpty else {
            throw IMAPError.invalidArgument("No header fields to fetch")
        }
        for field in fields where !Self.isValidFieldName(field) {
            throw IMAPError.invalidArgument("Invalid header field name: \(field)")
        }
        guard timeoutSeconds > 0 else {
            throw IMAPError.invalidArgument("Timeout must be positive: \(timeoutSeconds)")
        }
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        let attributes: [FetchAttribute] = [
            .uid,
            .bodySection(peek: true, .wholeMessageHeaderFields(fields), nil)
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

    /// An RFC 5322 field name: one or more printable US-ASCII characters
    /// other than the colon (RFC 5322 §3.6.8).
    static func isValidFieldName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { $0 >= 33 && $0 <= 126 && $0 != UInt8(ascii: ":") }
    }
}

extension SectionSpecifier {
    /// `HEADER.FIELDS (<fields>)` of the whole message, as ``FetchMessageInfoCommand``
    /// and ``FetchHeaderFieldsCommand`` request it.
    static func wholeMessageHeaderFields(_ fields: [String]) -> SectionSpecifier {
        SectionSpecifier(part: .init([]), kind: .headerFields(fields))
    }
}
