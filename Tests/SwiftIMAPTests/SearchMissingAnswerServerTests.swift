#if os(macOS) || os(Linux)
import Foundation
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
            reply(2, untagged: "* ESEARCH UID MIN 1 MAX 1"),
            reply(3, untagged: "* ESEARCH UID COUNT 1 MIN 1 MAX 1")
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

    @Test
    func emptyIMAP4rev2EsearchAnswerIsAnEmptyResult() async throws {
        try await withServer(capabilities: ["IMAP4rev1"], scripts: [reply(2, untagged: "* ESEARCH UID")]) { server, _ in
            let result: ExtendedSearchResult<SwiftMail.UID> = try await server.extendedSearch(criteria: [.all])
            #expect(result.all == nil)
            #expect(result.min == nil)
            #expect(result.max == nil)
        }
    }

    private func reply(_ occurrence: Int, untagged: String?) -> IMAPTestServer.Script {
        var actions: [IMAPTestServer.Action] = []
        if let untagged {
            actions.append(.send(Data((untagged + "\r\n").utf8), acknowledgement: "answer \(occurrence)"))
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
