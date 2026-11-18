import Foundation
import Testing
@testable import SwiftMail

/// Through the public API and a real connection: a search whose answer is missing fails, and
/// the connection stays usable for the next search.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SearchMissingAnswerServerTests {
    @Test
    func missingAnswerFailsAndTheNextSearchSucceeds() async throws {
        try await withServer(capabilities: ["IMAP4rev1", "AUTH=PLAIN", "UIDPLUS"], replies: [""]) { server in
            await #expect(throws: IMAPError.self) {
                let _: ExtendedSearchResult<SwiftMail.UID> = try await server.extendedSearch(criteria: [.all])
            }
            let result: ExtendedSearchResult<SwiftMail.UID> = try await server.extendedSearch(criteria: [.all])
            #expect(result.all?.toArray().map(\.value) == [1])
        }
    }

    @Test
    func missingRequestedCountFailsThroughTheCommand() async throws {
        let capabilities = ["IMAP4rev1", "AUTH=PLAIN", "UIDPLUS", "ESEARCH"]
        try await withServer(capabilities: capabilities, replies: ["* ESEARCH UID MIN 1 MAX 1"]) { server in
            await #expect(throws: IMAPError.self) {
                let _: ExtendedSearchResult<SwiftMail.UID> = try await server.searchCount(criteria: [.all])
            }
            let result: ExtendedSearchResult<SwiftMail.UID> = try await server.searchCount(criteria: [.all])
            #expect(result.count == 1)
        }
    }

    @Test
    func emptyIMAP4rev2EsearchAnswerIsAnEmptyResult() async throws {
        let replies = ["* ESEARCH (TAG \"{tag}\") UID"]
        try await withServer(capabilities: ["IMAP4rev1", "AUTH=PLAIN", "UIDPLUS"], replies: replies) { server in
            let result: ExtendedSearchResult<SwiftMail.UID> = try await server.extendedSearch(criteria: [.all])
            #expect(result.all == nil)
            #expect(result.min == nil)
            #expect(result.max == nil)
        }
    }

    private func withServer(
        capabilities: [String],
        replies: [String],
        body: (SwiftMail.IMAPServer) async throws -> Void
    ) async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let curDir = tempRoot.appendingPathComponent("Maildir/cur")
        try FileManager.default.createDirectory(at: curDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let sample = "From: a@example.com\r\nTo: b@example.com\r\nSubject: s\r\n"
            + "Date: Wed, 01 Jan 2020 00:00:00 +0000\r\n\r\nBody.\r\n"
        try #require(sample.data(using: .utf8)).write(to: curDir.appendingPathComponent("1.eml"))

        let testServer = try IMAPTestServer(
            username: "u", password: "p",
            uidSearchReplyOverrides: replies,
            advertisedCapabilities: capabilities,
            maildirURL: tempRoot.appendingPathComponent("Maildir"))
        try testServer.start()
        try await testServer.run {
            let server = SwiftMail.IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
            try await server.connect()
            try await server.login(username: "u", password: "p")
            _ = try await server.selectMailbox("INBOX")
            try await body(server)
            try await server.disconnect()
        }
    }
}
