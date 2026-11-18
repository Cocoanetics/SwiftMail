import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

/// A tagged OK only completes a search when the untagged answer the protocol requires arrived:
/// RFC 3501 §6.4.4 and RFC 9051 §6.4.4 require an untagged SEARCH (or ESEARCH) response even when
/// nothing matches (§7.2.5: `* SEARCH` with no numbers), and RFC 4731 §3.1 requires a requested
/// COUNT always and a requested ALL whenever something matched.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SearchResponseCompletenessTests {

    // MARK: - Helpers

    /// Run an `ExtendedSearchCommand` through the handler it builds, feeding `lines` as the
    /// server's reply (the tagged completion included).
    func runExtendedSearch(
        _ command: ExtendedSearchCommand<SwiftMail.UID>,
        tag: String,
        lines: [String]
    ) async throws -> ExtendedSearchResult<SwiftMail.UID> {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: ExtendedSearchResult<SwiftMail.UID>.self)
        try await channel.pipeline.addHandler(command.makeHandler(commandTag: tag, promise: promise))
        try await send(command.toTaggedCommand(tag: tag), on: channel)
        try await feed(lines, to: channel)
        return try await promise.futureResult.get()
    }

    func runPlainSearch(
        tag: String,
        lines: [String]
    ) async throws -> SwiftMail.MessageIdentifierSet<SwiftMail.UID> {
        let command = SearchCommand<SwiftMail.UID>(criteria: [.all])
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: SwiftMail.MessageIdentifierSet<SwiftMail.UID>.self)
        try await channel.pipeline.addHandler(command.makeHandler(commandTag: tag, promise: promise))
        try await send(command.toTaggedCommand(tag: tag), on: channel)
        try await feed(lines, to: channel)
        return try await promise.futureResult.get()
    }

    @discardableResult
    private func send(_ tagged: TaggedCommand, on channel: NIOAsyncTestingChannel) async throws -> String {
        let wrapped = IMAPClientHandler.OutboundIn.part(NIOIMAPCore.CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)
        let written = try await channel.readOutbound(as: ByteBuffer.self)
        return written.map { String(buffer: $0) } ?? ""
    }

    private func feed(_ lines: [String], to channel: NIOAsyncTestingChannel) async throws {
        for line in lines {
            var buffer = channel.allocator.buffer(capacity: line.utf8.count + 2)
            buffer.writeString(line + "\r\n")
            try await channel.writeInbound(buffer)
        }
    }

    /// The search must fail with the incomplete-answer error, naming what is missing.
    func expectIncomplete(naming missing: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("Expected the search to fail, but it succeeded")
        } catch IMAPError.commandFailed(let reason) {
            #expect(reason.contains(missing), "reason: \(reason)")
        } catch {
            Issue.record("Expected IMAPError.commandFailed, got \(error)")
        }
    }

    func esearchCommand(
        returnsAll: Bool = true,
        partialRange: NIOIMAPCore.PartialRange? = nil
    ) -> ExtendedSearchCommand<SwiftMail.UID> {
        ExtendedSearchCommand<SwiftMail.UID>(
            criteria: [.all], useEsearch: true, partialRange: partialRange, returnsAll: returnsAll
        )
    }

    func plainCommand(useSort: Bool = false) -> ExtendedSearchCommand<SwiftMail.UID> {
        ExtendedSearchCommand<SwiftMail.UID>(
            criteria: [.all], sortCriteria: useSort ? [.arrival] : [], useSort: useSort, useEsearch: false
        )
    }

    static let noAnswer = "no untagged"

    // MARK: - Missing untagged answer

    @Test
    func plainSearchOKWithoutUntaggedSearchFails() async {
        await expectIncomplete(naming: Self.noAnswer) {
            _ = try await runPlainSearch(tag: "C001", lines: ["C001 OK Search completed"])
        }
    }

    @Test
    func extendedSearchFallbackOKWithoutUntaggedSearchFails() async {
        let command = plainCommand()
        await expectIncomplete(naming: Self.noAnswer) {
            _ = try await runExtendedSearch(command, tag: "C002", lines: ["C002 OK Search completed"])
        }
    }

    @Test
    func esearchOKWithoutAnyUntaggedAnswerFails() async {
        await expectIncomplete(naming: Self.noAnswer) {
            _ = try await runExtendedSearch(esearchCommand(), tag: "C003", lines: ["C003 OK Search completed"])
        }
    }

    // MARK: - Incomplete ESEARCH

    @Test
    func esearchWithoutRequestedCountFails() async {
        let lines = ["* ESEARCH (TAG \"C004\") UID MIN 4 MAX 10 ALL 4,7,10", "C004 OK Search completed"]
        await expectIncomplete(naming: "COUNT") {
            _ = try await runExtendedSearch(esearchCommand(), tag: "C004", lines: lines)
        }
    }

    @Test
    func esearchWithPositiveCountButNoRequestedAllFails() async {
        let lines = ["* ESEARCH (TAG \"C005\") UID COUNT 3 MIN 4 MAX 10", "C005 OK Search completed"]
        await expectIncomplete(naming: "ALL") {
            _ = try await runExtendedSearch(esearchCommand(), tag: "C005", lines: lines)
        }
    }

    // MARK: - Real empty answers stay empty successes

    @Test
    func plainSearchWithNoNumbersIsEmpty() async throws {
        let result = try await runPlainSearch(tag: "C006", lines: ["* SEARCH", "C006 OK Search completed"])
        #expect(result.isEmpty)
    }

    @Test
    func extendedSearchFallbackWithNoNumbersIsEmpty() async throws {
        let command = plainCommand()
        let result = try await runExtendedSearch(command, tag: "C007", lines: ["* SEARCH", "C007 OK Search completed"])
        #expect(result.count == 0)
        #expect(result.all == nil)
    }

    @Test
    func esearchWithCountZeroAndNoAllIsEmpty() async throws {
        let lines = ["* ESEARCH (TAG \"C008\") UID COUNT 0", "C008 OK Search completed"]
        let result = try await runExtendedSearch(esearchCommand(), tag: "C008", lines: lines)
        #expect(result.count == 0)
        #expect(result.all == nil)
    }

    // MARK: - ALL not requested

    @Test
    func esearchCountOnlyWithoutAllSucceedsWhenAllWasNotRequested() async throws {
        let lines = ["* ESEARCH (TAG \"C009\") UID COUNT 3 MIN 4 MAX 10", "C009 OK Search completed"]
        let result = try await runExtendedSearch(esearchCommand(returnsAll: false), tag: "C009", lines: lines)
        #expect(result.count == 3)
        #expect(result.all == nil)
    }

    // MARK: - Every requested option is present when something matched

    @Test
    func esearchCompleteAnswerThroughCommandSucceeds() async throws {
        let lines = ["* ESEARCH (TAG \"C010\") UID COUNT 3 MIN 4 MAX 10 ALL 4,7,10", "C010 OK Search completed"]
        let result = try await runExtendedSearch(esearchCommand(), tag: "C010", lines: lines)
        #expect(result.count == 3)
        #expect(result.min?.value == 4)
        #expect(result.max?.value == 10)
        #expect(result.all?.toArray().map(\.value) == [4, 7, 10])
    }

    @Test
    func esearchWithPositiveCountButNoRequestedMinFails() async {
        let lines = ["* ESEARCH (TAG \"C011\") UID COUNT 3 MAX 10 ALL 4,7,10", "C011 OK Search completed"]
        await expectIncomplete(naming: "MIN") {
            _ = try await runExtendedSearch(esearchCommand(), tag: "C011", lines: lines)
        }
    }

    @Test
    func esearchWithPositiveCountButNoRequestedMaxFails() async {
        let lines = ["* ESEARCH (TAG \"C012\") UID COUNT 3 MIN 4", "C012 OK Search completed"]
        await expectIncomplete(naming: "MAX") {
            _ = try await runExtendedSearch(esearchCommand(returnsAll: false), tag: "C012", lines: lines)
        }
    }

    @Test
    func countOnlyEsearchWithoutRequestedCountFails() async {
        let lines = ["* ESEARCH (TAG \"C013\") UID MIN 4 MAX 10", "C013 OK Search completed"]
        await expectIncomplete(naming: "COUNT") {
            _ = try await runExtendedSearch(esearchCommand(returnsAll: false), tag: "C013", lines: lines)
        }
    }

    @Test
    func pagedEsearchWithPositiveCountButNoRequestedPartialFails() async {
        let range = NIOIMAPCore.PartialRange.first(NIOIMAPCore.SequenceRange(1...10))
        let lines = ["* ESEARCH (TAG \"C014\") UID COUNT 3 MIN 4 MAX 10", "C014 OK Search completed"]
        await expectIncomplete(naming: "PARTIAL") {
            _ = try await runExtendedSearch(esearchCommand(partialRange: range), tag: "C014", lines: lines)
        }
    }

    @Test
    func pagedEsearchWithEmptyWindowIsValid() async throws {
        let range = NIOIMAPCore.PartialRange.first(NIOIMAPCore.SequenceRange(1...10))
        let lines = ["* ESEARCH (TAG \"C015\") UID COUNT 0 PARTIAL (1:10 NIL)", "C015 OK Search completed"]
        let result = try await runExtendedSearch(esearchCommand(partialRange: range), tag: "C015", lines: lines)
        #expect(result.count == 0)
        #expect(result.partial?.results.isEmpty == true)
    }

    // MARK: - Only this command's answer counts

    @Test
    func esearchForAnotherTagIsNotAnAnswer() async {
        let lines = ["* ESEARCH (TAG \"OTHER\") UID COUNT 0", "C016 OK Search completed"]
        await expectIncomplete(naming: Self.noAnswer) {
            _ = try await runExtendedSearch(esearchCommand(), tag: "C016", lines: lines)
        }
    }

    @Test
    func unrelatedUntaggedDataIsNotAnAnswer() async {
        await expectIncomplete(naming: Self.noAnswer) {
            _ = try await runPlainSearch(tag: "C017", lines: ["* 5 EXISTS", "C017 OK Search completed"])
        }
        await expectIncomplete(naming: Self.noAnswer) {
            let lines = ["* 5 EXISTS", "C018 OK Search completed"]
            _ = try await runExtendedSearch(plainCommand(), tag: "C018", lines: lines)
        }
    }

    // MARK: - SORT and IMAP4rev2 answers

    @Test
    func emptySortAnswerIsEmpty() async throws {
        let lines = ["* SORT", "C019 OK Sort completed"]
        let result = try await runExtendedSearch(plainCommand(useSort: true), tag: "C019", lines: lines)
        #expect(result.count == 0)
        #expect(result.ordered == nil)
    }

    @Test
    func sortCompletedWithoutAnswerFails() async {
        await expectIncomplete(naming: Self.noAnswer) {
            _ = try await runExtendedSearch(plainCommand(useSort: true), tag: "C020", lines: ["C020 OK Sort completed"])
        }
    }

    @Test
    func plainSearchAnsweredWithEsearchIsAccepted() async throws {
        let emptyLines = ["* ESEARCH (TAG \"C021\") UID", "C021 OK Search completed"]
        let empty = try await runPlainSearch(tag: "C021", lines: emptyLines)
        #expect(empty.isEmpty)
        let lines = ["* ESEARCH (TAG \"C022\") UID ALL 4,7:8", "C022 OK Search completed"]
        let found = try await runPlainSearch(tag: "C022", lines: lines)
        #expect(found.toArray().map(\.value) == [4, 7, 8])
    }

    @Test
    func plainSearchIgnoresEsearchForAnotherTag() async {
        let lines = ["* ESEARCH (TAG \"OTHER\") UID ALL 4", "C023 OK Search completed"]
        await expectIncomplete(naming: Self.noAnswer) {
            _ = try await runPlainSearch(tag: "C023", lines: lines)
        }
    }
}

// MARK: - PARTIAL, fallbacks, ordering and compact answers

extension SearchResponseCompletenessTests {

    private static let window = NIOIMAPCore.PartialRange.first(NIOIMAPCore.SequenceRange(50...60))

    @Test
    func pagedCommandSendsCountMinMaxAndTheWindow() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let wire = try await send(esearchCommand(partialRange: Self.window).toTaggedCommand(tag: "C030"), on: channel)
        #expect(wire.contains("RETURN (COUNT MIN MAX PARTIAL 50:60)"), "wire: \(wire)")
    }

    @Test
    func pagedEsearchWithZeroCountButNoPartialFails() async {
        let lines = ["* ESEARCH (TAG \"C031\") UID COUNT 0", "C031 OK Search completed"]
        await expectIncomplete(naming: "PARTIAL") {
            _ = try await runExtendedSearch(esearchCommand(partialRange: Self.window), tag: "C031", lines: lines)
        }
    }

    @Test
    func pagedEsearchWithWindowPastTheMatchesIsEmpty() async throws {
        let lines = ["* ESEARCH (TAG \"C032\") UID COUNT 5 MIN 1 MAX 9 PARTIAL (50:60 NIL)", "C032 OK Search completed"]
        let result = try await runExtendedSearch(esearchCommand(partialRange: Self.window), tag: "C032", lines: lines)
        #expect(result.count == 5)
        #expect(result.partial?.results.isEmpty == true)
    }

    @Test
    func extendedSearchAcceptsIMAP4rev2EsearchToPlainSearch() async throws {
        let tagless = try await runExtendedSearch(plainCommand(), tag: "C033", lines: ["* ESEARCH UID", "C033 OK Done"])
        #expect(tagless.all == nil)
        let taggedLines = ["* ESEARCH (TAG \"C038\") UID", "C038 OK Done"]
        let tagged = try await runExtendedSearch(plainCommand(), tag: "C038", lines: taggedLines)
        #expect(tagged.all == nil)
        #expect(tagged.count == nil)
        let lines = ["* ESEARCH (TAG \"C034\") UID ALL 4", "C034 OK Done"]
        let found = try await runExtendedSearch(plainCommand(), tag: "C034", lines: lines)
        #expect(found.all?.toArray().map(\.value) == [4])
    }

    @Test
    func plainSearchAnswerToReturnRequestIsAccepted() async throws {
        let lines = ["* SEARCH 4 7", "C035 OK Search completed"]
        let result = try await runExtendedSearch(esearchCommand(), tag: "C035", lines: lines)
        #expect(result.count == 2)
        #expect(result.all?.toArray().map(\.value) == [4, 7])
    }

    @Test
    func ownAnswerAfterAForeignOneIsUsed() async throws {
        let lines = [
            "* ESEARCH (TAG \"OTHER\") UID COUNT 0",
            "* ESEARCH (TAG \"C036\") UID COUNT 1 MIN 4 MAX 4 ALL 4",
            "C036 OK Search completed"
        ]
        let result = try await runExtendedSearch(esearchCommand(), tag: "C036", lines: lines)
        #expect(result.count == 1)
        #expect(result.all?.toArray().map(\.value) == [4])
    }

    @Test
    func compactEsearchAnswerStaysCompact() async throws {
        let lines = ["* ESEARCH (TAG \"C037\") UID ALL 1:50000000", "C037 OK Search completed"]
        let result = try await runPlainSearch(tag: "C037", lines: lines)
        #expect(result.ranges == [1...50_000_000])
    }
}
