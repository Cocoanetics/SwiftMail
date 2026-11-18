#if os(macOS) || os(Linux)
import Foundation
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

/// Through the public API and a real connection: a search whose answer is missing fails, and
/// the connection stays usable for the next search. Connecting sends CAPABILITY (command 1),
/// so the first search is command 2.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SearchMissingAnswerServerTests {
    @Test
    func missingAnswerFailsAndTheNextSearchSucceeds() async throws {
        let scripts = [reply(2, untagged: nil), reply(3, untagged: "* SEARCH 1")]
        try await withServer(capabilities: ["IMAP4rev1"], scripts: scripts) { server, _ in
            await expectFailure(naming: "no untagged") {
                let _: ExtendedSearchResult<SwiftMail.UID> = try await server.extendedSearch(criteria: [.all])
            }
            let result: ExtendedSearchResult<SwiftMail.UID> = try await server.extendedSearch(criteria: [.all])
            #expect(result.all?.toArray().map(\.value) == [1])
        }
    }

    @Test
    func searchCountSendsCountMinMaxAndFailsWithoutTheCount() async throws {
        let scripts = [
            reply(2, untagged: "* ESEARCH (TAG \"{tag}\") UID MIN 1 MAX 1"),
            reply(3, untagged: "* ESEARCH (TAG \"{tag}\") UID COUNT 1 MIN 1 MAX 1")
        ]
        try await withServer(capabilities: ["IMAP4rev1", "ESEARCH"], scripts: scripts) { server, fixture in
            await expectFailure(naming: "COUNT") {
                let _: ExtendedSearchResult<SwiftMail.UID> = try await server.searchCount(criteria: [.all])
            }
            let result: ExtendedSearchResult<SwiftMail.UID> = try await server.searchCount(criteria: [.all])
            #expect(result.count == 1)
            #expect(result.all == nil)
            let searches = fixture.commandLog.filter { $0.uppercased().contains("UID SEARCH") }
            #expect(searches.count == 2)
            #expect(searches.allSatisfy { $0.uppercased().contains("UID SEARCH RETURN (COUNT MIN MAX) ALL") })
        }
    }

    /// An IMAP4rev2 server answers a plain UID SEARCH with an ESEARCH carrying the command's TAG;
    /// with no result data it reports that nothing matched (RFC 9051 §6.4.4, §7.3.4).
    @Test
    func emptyIMAP4rev2EsearchAnswerIsAnEmptyResult() async throws {
        let scripts = [reply(2, untagged: "* ESEARCH (TAG \"{tag}\") UID")]
        try await withServer(capabilities: ["IMAP4rev2"], scripts: scripts) { server, fixture in
            let result: ExtendedSearchResult<SwiftMail.UID> = try await server.extendedSearch(criteria: [.all])
            #expect(result.all == nil)
            #expect(result.min == nil)
            #expect(result.max == nil)
            let searches = fixture.commandLog.filter { $0.uppercased().contains("UID SEARCH") }
            #expect(searches.count == 1)
            #expect(searches.allSatisfy { !$0.uppercased().contains("RETURN") })
        }
    }

    /// A named connection installs the handler of the command it sends: a sorted page goes out
    /// as `UID SORT RETURN (… PARTIAL …)` and its correlated ESORT page comes back populated.
    @Test
    func namedConnectionSortPageReturnsItsWindow() async throws {
        let window = NIOIMAPCore.PartialRange.first(NIOIMAPCore.SequenceRange(1...3))
        let answer = "* ESEARCH (TAG \"{tag}\") UID COUNT 5 MIN 2 MAX 9 PARTIAL (1:3 9,2,5)\r\n"
        let page = IMAPTestServer.Script(connectionNumber: 2, occurrence: Self.namedSortOccurrence, actions: [
            .sendTagged(answer, acknowledgement: "page"),
            .taggedCompletion("OK UID SORT completed")
        ])
        let capabilities = ["IMAP4rev1", "AUTH=PLAIN", "SORT", "ESORT", "CONTEXT=SORT"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("cur"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try IMAPTestServer(advertisedCapabilities: capabilities, scripts: [page], maildirURL: root)
        try fixture.start()
        try await fixture.run {
            let server = SwiftMail.IMAPServer(host: "127.0.0.1", port: fixture.port, useTLS: false)
            try await server.connect()
            try await server.login(username: "testuser", password: "testpass")
            let named = try await server.connection(named: "sorted-page")
            // The search plan reads the capabilities, so fetch them before searching.
            try await named.fetchCapabilities()
            let result: ExtendedSearchResult<SwiftMail.UID> = try await named.extendedSearch(
                criteria: [.all], sortCriteria: [.arrival], partialRange: window
            )
            #expect(result.count == 5)
            #expect(result.partial?.range == window)
            #expect(result.partial?.results.toArray().map(\.value) == [2, 5, 9])
            let sorts = fixture.commandLog.filter { $0.uppercased().contains("UID SORT") }
            #expect(sorts.count == 1)
            #expect(sorts.allSatisfy { $0.uppercased().contains("UID SORT RETURN (COUNT MIN MAX PARTIAL 1:3)") },
                    "commands: \(fixture.commandLog)")
            try await server.disconnect()
        }
        #expect(fixture.fixtureFailures.isEmpty)
    }

    /// The named connection's commands: CAPABILITY on connect, LOGIN, CAPABILITY after LOGIN,
    /// the test's own CAPABILITY, then the search.
    private static let namedSortOccurrence = 5

    private func reply(_ occurrence: Int, untagged: String?) -> IMAPTestServer.Script {
        var actions: [IMAPTestServer.Action] = []
        if let untagged {
            actions.append(.sendTagged(untagged + "\r\n", acknowledgement: "answer \(occurrence)"))
        }
        actions.append(.taggedCompletion("OK UID SEARCH completed"))
        return IMAPTestServer.Script(connectionNumber: 1, occurrence: occurrence, actions: actions)
    }

    private func expectFailure(naming missing: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("Expected the search to fail, but it succeeded")
        } catch IMAPError.commandFailed(let reason) {
            #expect(reason.contains(missing), "reason: \(reason)")
        } catch {
            Issue.record("Expected IMAPError.commandFailed, got \(error)")
        }
    }

    private func withServer(
        capabilities: [String],
        scripts: [IMAPTestServer.Script],
        body: (SwiftMail.IMAPServer, IMAPTestServer) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("cur"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("new"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try IMAPTestServer(advertisedCapabilities: capabilities, scripts: scripts, maildirURL: root)
        try fixture.start()
        try await fixture.run {
            let server = SwiftMail.IMAPServer(host: "127.0.0.1", port: fixture.port, useTLS: false)
            try await server.connect()
            await server.primaryConnection.markSessionAuthenticated()
            do {
                try await body(server, fixture)
                try await server.disconnect()
            } catch {
                try? await server.disconnect()
                throw error
            }
        }
        #expect(fixture.fixtureFailures.isEmpty)
    }
}
#endif
