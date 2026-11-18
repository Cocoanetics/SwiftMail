import Foundation
import NIO
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

// MARK: - Which answer forms each command accepts

extension SearchResponseCompletenessTests {

    private static let page = NIOIMAPCore.PartialRange.first(NIOIMAPCore.SequenceRange(50...60))

    /// Run a `SearchCommand` (SEARCH or SORT) through its handler and return the result.
    private func runSearchCommand<T: SwiftMail.MessageIdentifier>(
        _ command: SearchCommand<T>,
        tag: String,
        lines: [String]
    ) async throws -> SwiftMail.MessageIdentifierSet<T> {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: SwiftMail.MessageIdentifierSet<T>.self)
        try await channel.pipeline.addHandler(command.makeHandler(commandTag: tag, promise: promise))
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command.toTaggedCommand(tag: tag))))
        _ = try await channel.readOutbound(as: ByteBuffer.self)
        for line in lines {
            try await channel.writeInbound(ByteBuffer(string: line + "\r\n"))
        }
        return try await promise.futureResult.get()
    }

    private func wire(of command: ExtendedSearchCommand<SwiftMail.UID>, tag: String) async throws -> String {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command.toTaggedCommand(tag: tag))))
        return try await channel.readOutbound(as: ByteBuffer.self).map { String(buffer: $0) } ?? ""
    }

    private func sortCommand(partialRange: NIOIMAPCore.PartialRange? = nil) -> ExtendedSearchCommand<SwiftMail.UID> {
        ExtendedSearchCommand<SwiftMail.UID>(
            criteria: [.all], sortCriteria: [.arrival], useSort: true, useEsearch: true, partialRange: partialRange
        )
    }

    // MARK: A SORT without RETURN is answered only by SORT (RFC 5256 §3, RFC 5267 §3)

    @Test
    func plainSortSendsNoReturnAndIgnoresAnEsearch() async throws {
        let sent = try await wire(of: plainCommand(useSort: true), tag: "C060")
        #expect(sent.contains("UID SORT (ARRIVAL)") && !sent.contains("RETURN"), "wire: \(sent)")
        await expectIncomplete(naming: Self.noAnswer) {
            let lines = ["* ESEARCH (TAG \"C061\") UID COUNT 1 MIN 4 MAX 4 ALL 4", "C061 OK Sort completed"]
            _ = try await runExtendedSearch(plainCommand(useSort: true), tag: "C061", lines: lines)
        }
        await expectIncomplete(naming: Self.noAnswer) {
            let command = SearchCommand<SwiftMail.UID>(criteria: [.all], sortCriteria: [.arrival], useSort: true)
            let lines = ["* ESEARCH (TAG \"C062\") UID ALL 4", "C062 OK Done"]
            _ = try await runSearchCommand(command, tag: "C062", lines: lines)
        }
    }

    @Test
    func sortWithReturnIsAnsweredByEsearch() async throws {
        let lines = ["* ESEARCH (TAG \"C063\") UID COUNT 2 MIN 4 MAX 9 ALL 4,9", "C063 OK Sort completed"]
        let result = try await runExtendedSearch(sortCommand(), tag: "C063", lines: lines)
        #expect(result.count == 2)
        #expect(result.all?.toArray().map(\.value) == [4, 9])
    }

    @Test
    func nonEmptySortAnswerKeepsTheServerOrder() async throws {
        let lines = ["* SORT 9 4 7", "C064 OK Sort completed"]
        let result = try await runExtendedSearch(plainCommand(useSort: true), tag: "C064", lines: lines)
        #expect(result.ordered?.map(\.value) == [9, 4, 7])
        #expect(result.count == 3)
    }

    // MARK: A PARTIAL request is answered only by ESEARCH (RFC 4731 §3.1, RFC 9394 §3.1)

    @Test
    func listAnswerToAPagedRequestIsMissing() async {
        await expectIncomplete(naming: Self.noAnswer) {
            let lines = ["* SEARCH 4 7", "C065 OK Search completed"]
            _ = try await runExtendedSearch(esearchCommand(partialRange: Self.page), tag: "C065", lines: lines)
        }
        await expectIncomplete(naming: Self.noAnswer) {
            let lines = ["* SORT 7 4", "C066 OK Sort completed"]
            _ = try await runExtendedSearch(sortCommand(partialRange: Self.page), tag: "C066", lines: lines)
        }
    }

    @Test
    func pagedSortEsearchWithoutRequestedPartialFails() async {
        let lines = ["* ESEARCH (TAG \"C067\") UID COUNT 70 MIN 1 MAX 90", "C067 OK Sort completed"]
        await expectIncomplete(naming: "PARTIAL") {
            _ = try await runExtendedSearch(sortCommand(partialRange: Self.page), tag: "C067", lines: lines)
        }
    }

    // MARK: Plain SEARCH answers

    @Test
    func plainSearchReturnsItsListAndItsEsearchAll() async throws {
        let listed = try await runPlainSearch(tag: "C068", lines: ["* SEARCH 4 7", "C068 OK Done"])
        #expect(listed.toArray().map(\.value) == [4, 7])
        let lines = ["* ESEARCH (TAG \"C069\") UID COUNT 2 ALL 4,7", "C069 OK Done"]
        let esearched = try await runPlainSearch(tag: "C069", lines: lines)
        #expect(esearched.toArray().map(\.value) == [4, 7])
        let emptyLines = ["* ESEARCH (TAG \"C070\") UID COUNT 0", "C070 OK Done"]
        let empty = try await runPlainSearch(tag: "C070", lines: emptyLines)
        #expect(empty.isEmpty)
    }

    @Test
    func plainSearchEsearchWithMinOrMaxAloneFails() async {
        await expectIncomplete(naming: "ALL") {
            _ = try await runPlainSearch(tag: "C071", lines: ["* ESEARCH (TAG \"C071\") UID MIN 4", "C071 OK Done"])
        }
        await expectIncomplete(naming: "ALL") {
            let lines = ["* ESEARCH (TAG \"C072\") UID MAX 9", "C072 OK Done"]
            _ = try await runExtendedSearch(plainCommand(), tag: "C072", lines: lines)
        }
    }

    @Test
    func bareEsearchToACountRequestFails() async {
        await expectIncomplete(naming: "COUNT") {
            let lines = ["* ESEARCH (TAG \"C073\") UID", "C073 OK Done"]
            _ = try await runExtendedSearch(esearchCommand(returnsAll: false), tag: "C073", lines: lines)
        }
    }

    @Test
    func sequenceSearchIgnoresAUIDEsearch() async {
        await expectIncomplete(naming: Self.noAnswer) {
            let command = SearchCommand<SwiftMail.SequenceNumber>(criteria: [.all])
            let lines = ["* ESEARCH (TAG \"C074\") UID ALL 4", "C074 OK Done"]
            _ = try await runSearchCommand(command, tag: "C074", lines: lines)
        }
    }
}
