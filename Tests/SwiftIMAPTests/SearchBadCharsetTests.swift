import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

private typealias UID = SwiftMail.UID

/// RFC 3501 §7.1 lets a server refuse the CHARSET a SEARCH carried with `NO [BADCHARSET ...]`,
/// optionally listing the charsets it does support; Exchange Online answers every
/// `CHARSET UTF-8` search that way. Both search handlers surface it as a typed error and keep
/// every other response code readable in the failure text instead of dropping it.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SearchBadCharsetTests {
    @Test
    func extendedSearchSurfacesBadCharsetWithTheServersList() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: ExtendedSearchResult<UID>.self)
        try await channel.pipeline.addHandler(ExtendedSearchHandler<UID>(commandTag: "B001", promise: promise))
        try await Self.send(Self.extendedSearch(tag: "B001"), on: channel)
        try await Self.respond("B001 NO [BADCHARSET (US-ASCII)] The specified charset is not supported.", on: channel)

        guard case .searchCharsetNotSupported(let supportedCharsets, let reason)? =
            await Self.failure(of: promise.futureResult) else {
            Issue.record("Expected searchCharsetNotSupported")
            return
        }
        #expect(supportedCharsets == ["US-ASCII"])
        #expect(reason == "Extended search failed: NO [BADCHARSET (US-ASCII)] The specified charset is not supported.")
    }

    @Test
    func plainSearchSurfacesBadCharsetWithoutAList() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: MessageIdentifierSet<UID>.self)
        try await channel.pipeline.addHandler(SearchHandler<UID>(commandTag: "B002", promise: promise))
        try await Self.send(Self.plainSearch(tag: "B002"), on: channel)
        try await Self.respond("B002 NO [BADCHARSET] Unsupported charset", on: channel)

        guard case .searchCharsetNotSupported(let supportedCharsets, let reason)? =
            await Self.failure(of: promise.futureResult) else {
            Issue.record("Expected searchCharsetNotSupported")
            return
        }
        #expect(supportedCharsets.isEmpty)
        #expect(reason == "Search failed: NO [BADCHARSET] Unsupported charset")
    }

    @Test
    func untaggedBadCharsetFailsTheExtendedSearchBeforeTheTaggedLine() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: ExtendedSearchResult<UID>.self)
        try await channel.pipeline.addHandler(ExtendedSearchHandler<UID>(commandTag: "B003", promise: promise))
        try await Self.send(Self.extendedSearch(tag: "B003"), on: channel)
        try await Self.respond("* NO [BADCHARSET (US-ASCII UTF-16)] Charset not supported", on: channel)

        guard case .searchCharsetNotSupported(let supportedCharsets, let reason)? =
            await Self.failure(of: promise.futureResult) else {
            Issue.record("Expected searchCharsetNotSupported")
            return
        }
        #expect(supportedCharsets == ["US-ASCII", "UTF-16"])
        #expect(reason == "Extended search failed: NO [BADCHARSET (US-ASCII UTF-16)] Charset not supported")
    }

    @Test
    func otherResponseCodesStayReadableInTheFailureText() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: ExtendedSearchResult<UID>.self)
        try await channel.pipeline.addHandler(ExtendedSearchHandler<UID>(commandTag: "B004", promise: promise))
        try await Self.send(Self.extendedSearch(tag: "B004"), on: channel)
        try await Self.respond("B004 NO [NONEXISTENT] Unknown Mailbox: Foo (Failure)", on: channel)

        guard case .commandFailed(let reason)? = await Self.failure(of: promise.futureResult) else {
            Issue.record("Expected commandFailed")
            return
        }
        #expect(reason == "Extended search failed: NO [NONEXISTENT] Unknown Mailbox: Foo (Failure)")
    }

    @Test
    func rejectionsWithoutAResponseCodeKeepTheirWording() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: MessageIdentifierSet<UID>.self)
        try await channel.pipeline.addHandler(SearchHandler<UID>(commandTag: "B005", promise: promise))
        try await Self.send(Self.plainSearch(tag: "B005"), on: channel)
        try await Self.respond("B005 BAD Could not parse command", on: channel)

        guard case .commandFailed(let reason)? = await Self.failure(of: promise.futureResult) else {
            Issue.record("Expected commandFailed")
            return
        }
        #expect(reason == "Search failed: BAD Could not parse command")
    }

    @Test
    func descriptionsNameTheCharsetsTheServerListed() {
        let listed = IMAPError.searchCharsetNotSupported(supportedCharsets: ["US-ASCII"], reason: "reason")
        let unlisted = IMAPError.searchCharsetNotSupported(supportedCharsets: [], reason: "reason")

        #expect(listed.description == "Search charset not supported: reason")
        #expect(
            listed.failureReason
                == "The server does not support the charset the search used; it supports US-ASCII"
        )
        #expect(unlisted.failureReason == "The server does not support the charset the search used")
        #expect(
            listed.recoverySuggestion
                == "Retry with a charset the server supports: US-ASCII-only search text for SEARCH, "
                + "or a supported sortCharset for SORT."
        )
    }

    @Test
    func rejectionsWithoutTextKeepTheirWording() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: MessageIdentifierSet<UID>.self)
        try await channel.pipeline.addHandler(SearchHandler<UID>(commandTag: "B006", promise: promise))
        try await Self.send(Self.plainSearch(tag: "B006"), on: channel)
        try await Self.respond("B006 NO", on: channel)

        guard case .commandFailed(let reason)? = await Self.failure(of: promise.futureResult) else {
            Issue.record("Expected commandFailed")
            return
        }
        #expect(reason == "Search failed: NO ")
    }

    @Test
    func badCharsetWithoutTextCarriesTheCodeAlone() {
        let responseText = NIOIMAPCore.ResponseText(code: .badCharset(["US-ASCII"]), text: "")
        let error = IMAPError.searchRejected(operation: "Extended search", status: "NO", responseText: responseText)

        guard case .searchCharsetNotSupported(let supportedCharsets, let reason) = error else {
            Issue.record("Expected searchCharsetNotSupported")
            return
        }
        #expect(supportedCharsets == ["US-ASCII"])
        #expect(reason == "Extended search failed: NO [BADCHARSET (US-ASCII)] ")
    }

    // MARK: - Helpers

    private static func extendedSearch(tag: String) -> NIOIMAPCore.TaggedCommand {
        ExtendedSearchCommand<UID>(criteria: [.subject("Morning brief")], useEsearch: true)
            .toTaggedCommand(tag: tag)
    }

    private static func plainSearch(tag: String) -> NIOIMAPCore.TaggedCommand {
        SearchCommand<UID>(criteria: [.text("invoice")]).toTaggedCommand(tag: tag)
    }

    private static func send(_ tagged: NIOIMAPCore.TaggedCommand, on channel: NIOAsyncTestingChannel) async throws {
        let wrapped = IMAPClientHandler.OutboundIn.part(NIOIMAPCore.CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)
        _ = try await channel.readOutbound(as: ByteBuffer.self)
    }

    private static func respond(_ line: String, on channel: NIOAsyncTestingChannel) async throws {
        var buffer = channel.allocator.buffer(capacity: line.utf8.count + 2)
        buffer.writeString(line + "\r\n")
        try await channel.writeInbound(buffer)
    }

    private static func failure<T>(of future: EventLoopFuture<T>) async -> IMAPError? {
        do {
            _ = try await future.get()
            Issue.record("Expected the search to fail")
            return nil
        } catch let error as IMAPError {
            return error
        } catch {
            Issue.record("Unexpected error: \(error)")
            return nil
        }
    }
}
