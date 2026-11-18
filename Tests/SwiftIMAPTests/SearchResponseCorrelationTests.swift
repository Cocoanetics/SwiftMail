import Foundation
import NIO
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

// MARK: - Only an ESEARCH correlated to this command answers it

/// An ESEARCH without a TAG correlator "was not caused by a particular IMAP command"
/// (RFC 9051 §7.3.4, RFC 4466 §2.6.2), so it never answers, fills or empties a search.
extension SearchResponseCompletenessTests {

    @Test
    func uncorrelatedEsearchDoesNotAnswerAnExtendedSearch() async {
        await expectIncomplete(naming: Self.noAnswer) {
            let lines = ["* ESEARCH UID COUNT 1 MIN 4 MAX 4 ALL 4", "C080 OK Search completed"]
            _ = try await runExtendedSearch(esearchCommand(), tag: "C080", lines: lines)
        }
        await expectIncomplete(naming: Self.noAnswer) {
            let lines = ["* ESEARCH UID COUNT 0", "C081 OK Search completed"]
            _ = try await runExtendedSearch(esearchCommand(), tag: "C081", lines: lines)
        }
        await expectIncomplete(naming: Self.noAnswer) {
            _ = try await runExtendedSearch(plainCommand(), tag: "C082", lines: ["* ESEARCH UID ALL 4", "C082 OK Done"])
        }
    }

    @Test
    func uncorrelatedEsearchDoesNotAnswerAPlainSearch() async {
        await expectIncomplete(naming: Self.noAnswer) {
            _ = try await runPlainSearch(tag: "C083", lines: ["* ESEARCH UID ALL 4", "C083 OK Done"])
        }
        await expectIncomplete(naming: Self.noAnswer) {
            let command = SearchCommand<SwiftMail.SequenceNumber>(criteria: [.all])
            _ = try await runSearchCommand(command, tag: "C084", lines: ["* ESEARCH ALL 2:3", "C084 OK Done"])
        }
    }

    @Test
    func emptyAnswerAfterUncorrelatedDataStaysEmpty() async throws {
        let lines = [
            "* ESEARCH UID COUNT 1 MIN 9 MAX 9 ALL 9",
            "* ESEARCH (TAG \"C085\") UID COUNT 0",
            "C085 OK Search completed"
        ]
        let result = try await runExtendedSearch(esearchCommand(), tag: "C085", lines: lines)
        #expect(result.count == 0)
        #expect(result.min == nil)
        #expect(result.max == nil)
        #expect(result.all == nil)

        let fallbackLines = ["* ESEARCH UID ALL 9", "* ESEARCH (TAG \"C086\") UID", "C086 OK Done"]
        let fallback = try await runExtendedSearch(plainCommand(), tag: "C086", lines: fallbackLines)
        #expect(fallback.all == nil)

        let plainLines = ["* ESEARCH UID ALL 9", "* ESEARCH (TAG \"C087\") UID", "C087 OK Done"]
        let plain = try await runPlainSearch(tag: "C087", lines: plainLines)
        #expect(plain.isEmpty)
    }
}

// MARK: - The options sent are the options checked

extension SearchResponseCompletenessTests {

    private static let sortPage = NIOIMAPCore.PartialRange.first(NIOIMAPCore.SequenceRange(50...60))

    @Test
    func sequenceSearchSendsAndChecksItsReturnOptions() async throws {
        let command = ExtendedSearchCommand<SwiftMail.SequenceNumber>(criteria: [.all], useEsearch: true)
        let lines = ["* ESEARCH (TAG \"C090\") COUNT 2 MIN 1 MAX 5 ALL 1,5", "C090 OK Search completed"]
        let (wire, result) = try await runExtendedSearchOnWire(command, tag: "C090", lines: lines)
        #expect(wire == "C090 SEARCH RETURN (COUNT MIN MAX ALL) ALL\r\n", "wire: \(wire)")
        #expect(result.count == 2)
        #expect(result.min?.value == 1)
        #expect(result.max?.value == 5)
        #expect(result.all?.toArray().map(\.value) == [1, 5])

        await expectIncomplete(naming: "COUNT") {
            let omitted = ["* ESEARCH (TAG \"C091\") MIN 1 MAX 5 ALL 1,5", "C091 OK Search completed"]
            _ = try await runExtendedSearch(command, tag: "C091", lines: omitted)
        }
    }

    @Test
    func sortPageReturnsItsWindowForSortAndUIDSort() async throws {
        try await expectSortPage(SwiftMail.SequenceNumber.self, tag: "C092", verb: "SORT")
        try await expectSortPage(SwiftMail.UID.self, tag: "C093", verb: "UID SORT")
    }

    private func expectSortPage<T: SwiftMail.MessageIdentifier>(
        _: T.Type,
        tag: String,
        verb: String
    ) async throws {
        let command = ExtendedSearchCommand<T>(
            criteria: [.all], sortCriteria: [.arrival], useSort: true, useEsearch: true, partialRange: Self.sortPage
        )
        let uid = T.self == SwiftMail.UID.self ? " UID" : ""
        let lines = [
            "* ESEARCH (TAG \"\(tag)\")\(uid) COUNT 70 MIN 1 MAX 90 PARTIAL (50:60 9,4,7)",
            "\(tag) OK Sort completed"
        ]
        let (wire, result) = try await runExtendedSearchOnWire(command, tag: tag, lines: lines)
        #expect(wire.hasPrefix("\(tag) \(verb) RETURN (COUNT MIN MAX PARTIAL 50:60) (ARRIVAL)"), "wire: \(wire)")
        #expect(result.count == 70)
        #expect(result.min?.value == 1)
        #expect(result.max?.value == 90)
        #expect(result.partial?.range == Self.sortPage)
        #expect(result.partial?.results.toArray().map(\.value) == [4, 7, 9])
    }
}
