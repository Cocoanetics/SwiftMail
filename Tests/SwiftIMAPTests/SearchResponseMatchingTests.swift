import Foundation
import NIO
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

// MARK: - Only an answer to this command counts

extension SearchResponseCompletenessTests {

    @Test
    func uidCommandAnsweredWithoutUIDIndicatorIsMissing() async {
        let lines = ["* ESEARCH (TAG \"C040\") COUNT 1 MIN 4 MAX 4 ALL 4", "C040 OK Search completed"]
        await expectIncomplete(naming: Self.noAnswer) {
            _ = try await runExtendedSearch(esearchCommand(), tag: "C040", lines: lines)
        }
        await expectIncomplete(naming: Self.noAnswer) {
            let plainLines = ["* ESEARCH (TAG \"C041\") ALL 4", "C041 OK Search completed"]
            _ = try await runPlainSearch(tag: "C041", lines: plainLines)
        }
    }

    @Test
    func sortAnswerToSearchIsMissing() async {
        await expectIncomplete(naming: Self.noAnswer) {
            _ = try await runPlainSearch(tag: "C042", lines: ["* SORT 4", "C042 OK Search completed"])
        }
        await expectIncomplete(naming: Self.noAnswer) {
            _ = try await runExtendedSearch(plainCommand(), tag: "C043", lines: ["* SORT 4", "C043 OK Done"])
        }
    }

    @Test
    func searchAnswerToSortIsMissing() async {
        await expectIncomplete(naming: Self.noAnswer) {
            let lines = ["* SEARCH 4", "C044 OK Sort completed"]
            _ = try await runExtendedSearch(plainCommand(useSort: true), tag: "C044", lines: lines)
        }
    }

    // MARK: MIN or MAX shows matches as well as COUNT

    @Test
    func requestedAllMissingWithMinOrMaxFails() async {
        let lines = ["* ESEARCH (TAG \"C045\") UID COUNT 0 MIN 4 MAX 9", "C045 OK Search completed"]
        await expectIncomplete(naming: "ALL") {
            _ = try await runExtendedSearch(esearchCommand(), tag: "C045", lines: lines)
        }
    }

    @Test
    func plainSearchEsearchWithMinButNoDefaultAllFails() async {
        await expectIncomplete(naming: "ALL") {
            let lines = ["* ESEARCH (TAG \"C046\") UID MIN 4", "C046 OK Search completed"]
            _ = try await runExtendedSearch(plainCommand(), tag: "C046", lines: lines)
        }
        await expectIncomplete(naming: "ALL") {
            let lines = ["* ESEARCH (TAG \"C047\") UID MAX 9", "C047 OK Search completed"]
            _ = try await runPlainSearch(tag: "C047", lines: lines)
        }
    }

    @Test
    func minAndMaxWithoutAllAreValidWhenAllWasNotRequested() async throws {
        let lines = ["* ESEARCH (TAG \"C048\") UID COUNT 2 MIN 4 MAX 9", "C048 OK Search completed"]
        let result = try await runExtendedSearch(esearchCommand(returnsAll: false), tag: "C048", lines: lines)
        #expect(result.min?.value == 4)
        #expect(result.max?.value == 9)
        #expect(result.all == nil)
    }

    // MARK: Another command's data never fills this answer

    @Test
    func foreignAllCannotFillAMissingAll() async {
        let lines = [
            "* ESEARCH (TAG \"OTHER\") UID ALL 4",
            "* ESEARCH (TAG \"C050\") UID COUNT 1 MIN 4 MAX 4",
            "C050 OK Search completed"
        ]
        await expectIncomplete(naming: "ALL") {
            _ = try await runExtendedSearch(esearchCommand(), tag: "C050", lines: lines)
        }
    }

    @Test
    func foreignAllAddsNothingToAPlainResult() async throws {
        let lines = ["* ESEARCH (TAG \"OTHER\") UID ALL 9", "* ESEARCH (TAG \"C051\") UID ALL 4", "C051 OK Done"]
        let result = try await runPlainSearch(tag: "C051", lines: lines)
        #expect(result.toArray().map(\.value) == [4])
    }

    // MARK: Implicit ALL with COUNT, empty answers and compact sets

    @Test
    func plainSearchEsearchWithPositiveCountButNoDefaultAllFails() async {
        await expectIncomplete(naming: "ALL") {
            let lines = ["* ESEARCH (TAG \"C052\") UID COUNT 1", "C052 OK Done"]
            _ = try await runExtendedSearch(plainCommand(), tag: "C052", lines: lines)
        }
        await expectIncomplete(naming: "ALL") {
            _ = try await runPlainSearch(tag: "C053", lines: ["* ESEARCH (TAG \"C053\") UID COUNT 1", "C053 OK Done"])
        }
    }

    @Test
    func emptyPlainSearchAnswerToReturnRequestIsEmpty() async throws {
        let result = try await runExtendedSearch(esearchCommand(), tag: "C054", lines: ["* SEARCH", "C054 OK Done"])
        #expect(result.count == 0)
        #expect(result.all == nil)
    }

    @Test
    func disjointCompactAnswerStaysCompact() async throws {
        let lines = ["* ESEARCH (TAG \"C055\") UID ALL 1:50000000,60000000:90000000", "C055 OK Done"]
        let result = try await runPlainSearch(tag: "C055", lines: lines)
        #expect(result.ranges == [1...50_000_000, 60_000_000...90_000_000])
    }

    // MARK: SORT and sequence-number answers

    @Test
    func pagedSortSendsCountMinMaxAndTheWindow() async throws {
        let range = NIOIMAPCore.PartialRange.first(NIOIMAPCore.SequenceRange(50...60))
        let command = ExtendedSearchCommand<SwiftMail.UID>(
            criteria: [.all], sortCriteria: [.arrival], useSort: true, useEsearch: true, partialRange: range
        )
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let tagged = IMAPClientHandler.OutboundIn.part(.tagged(command.toTaggedCommand(tag: "C056")))
        try await channel.writeAndFlush(tagged)
        let wire = try await channel.readOutbound(as: ByteBuffer.self).map { String(buffer: $0) } ?? ""
        #expect(wire.contains("UID SORT RETURN (COUNT MIN MAX PARTIAL 50:60)"), "wire: \(wire)")
    }

    @Test
    func pagedEsearchWithoutRequestedMinFails() async {
        let range = NIOIMAPCore.PartialRange.first(NIOIMAPCore.SequenceRange(50...60))
        let lines = ["* ESEARCH (TAG \"C057\") UID COUNT 3 MAX 9 PARTIAL (50:60 4)", "C057 OK Done"]
        await expectIncomplete(naming: "MIN") {
            _ = try await runExtendedSearch(esearchCommand(partialRange: range), tag: "C057", lines: lines)
        }
    }

    @Test
    func plainSortCommandAcceptsAnEmptySortAnswer() async throws {
        let command = SearchCommand<SwiftMail.UID>(criteria: [.all], sortCriteria: [.arrival], useSort: true)
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: SwiftMail.MessageIdentifierSet<SwiftMail.UID>.self)
        try await channel.pipeline.addHandler(command.makeHandler(commandTag: "C058", promise: promise))
        let tagged = IMAPClientHandler.OutboundIn.part(.tagged(command.toTaggedCommand(tag: "C058")))
        try await channel.writeAndFlush(tagged)
        _ = try await channel.readOutbound(as: ByteBuffer.self)
        for line in ["* SORT", "C058 OK Sort completed"] {
            try await channel.writeInbound(ByteBuffer(string: line + "\r\n"))
        }
        #expect(try await promise.futureResult.get().isEmpty)
    }

    @Test
    func sequenceSearchAcceptsACorrelatedEsearch() async throws {
        let command = SearchCommand<SwiftMail.SequenceNumber>(criteria: [.all])
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: SwiftMail.MessageIdentifierSet<SwiftMail.SequenceNumber>.self)
        try await channel.pipeline.addHandler(command.makeHandler(commandTag: "C059", promise: promise))
        let tagged = IMAPClientHandler.OutboundIn.part(.tagged(command.toTaggedCommand(tag: "C059")))
        try await channel.writeAndFlush(tagged)
        _ = try await channel.readOutbound(as: ByteBuffer.self)
        for line in ["* ESEARCH (TAG \"C059\") ALL 2:3", "C059 OK Search completed"] {
            try await channel.writeInbound(ByteBuffer(string: line + "\r\n"))
        }
        #expect(try await promise.futureResult.get().toArray().map(\.value) == [2, 3])
    }
}
