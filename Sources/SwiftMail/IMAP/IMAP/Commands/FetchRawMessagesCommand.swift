// FetchRawMessagesCommand.swift
// Command for fetching the complete raw bytes of several messages in one FETCH

import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

/// Fetches `BODY.PEEK[]` for a set of messages in a single FETCH, handing each
/// message's exact bytes to `sink`, keyed by identifier, as soon as its FETCH
/// response ends. A message the server does not answer is never passed on.
struct FetchRawMessagesCommand<T: MessageIdentifier>: IMAPTaggedCommand {
    typealias ResultType = Void
    typealias HandlerType = FetchRawMessagesHandler<T>

    /// The most messages one command asks for when the caller sets no chunk size.
    static var defaultChunkSize: Int { 25 }

    /// The deadline for one command when the caller sets none.
    static var defaultTimeoutSeconds: Int { 60 }

    /// The messages to fetch
    let identifierSet: MessageIdentifierSet<T>

    /// The deadline for the server's complete answer to this command
    let timeoutSeconds: Int

    /// Receives each message's bytes on the connection's event loop; it must not block.
    let sink: @Sendable (T, Data) -> Void

    init(
        identifierSet: MessageIdentifierSet<T>,
        timeoutSeconds: Int? = nil,
        sink: @escaping @Sendable (T, Data) -> Void
    ) {
        self.identifierSet = identifierSet
        self.timeoutSeconds = timeoutSeconds ?? Self.defaultTimeoutSeconds
        self.sink = sink
    }

    /// The commands that fetch `identifierSet`, at most `chunkSize` messages
    /// each (``defaultChunkSize`` when `nil`; zero or less sends one command).
    /// A set that ends in `*` is sent whole: it cannot be split without
    /// expanding the open range.
    static func chunks(
        identifierSet: MessageIdentifierSet<T>,
        chunkSize: Int?,
        timeoutSeconds: Int?,
        sink: @escaping @Sendable (T, Data) -> Void
    ) throws -> [FetchRawMessagesCommand<T>] {
        guard !identifierSet.isEmpty else {
            throw IMAPError.emptyIdentifierSet
        }
        let sets = identifierSet.contains(T.latest)
            ? [identifierSet]
            : identifierSet.chunked(size: chunkSize ?? defaultChunkSize)
        return sets.map { FetchRawMessagesCommand(identifierSet: $0, timeoutSeconds: timeoutSeconds, sink: sink) }
    }

    func validate() throws {
        guard !identifierSet.isEmpty else {
            throw IMAPError.emptyIdentifierSet
        }
        guard timeoutSeconds > 0 else {
            throw IMAPError.invalidArgument("Timeout must be positive: \(timeoutSeconds)")
        }
    }

    func makeHandler(commandTag: String, promise: EventLoopPromise<Void>) -> FetchRawMessagesHandler<T> {
        FetchRawMessagesHandler(commandTag: commandTag, promise: promise, sink: sink)
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        let attributes: [FetchAttribute] = [
            .uid,
            .bodySection(peek: true, .complete, nil)
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
