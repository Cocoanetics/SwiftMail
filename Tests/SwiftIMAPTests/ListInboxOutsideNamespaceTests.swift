import Testing
import Foundation
@testable import SwiftMail

#if os(macOS)
    /// INBOX is listed even when the personal namespace prefix does not contain it.
    ///
    /// RFC 2342 §6 and RFC 3501 §5.1: INBOX always exists and need not sit inside the personal
    /// namespace. A server announcing `(("Mail/" "/"))` answers `LIST "" "Mail/*"` and
    /// `LIST "" "Mail"` without INBOX, so a namespace-based listing has to ask for it by name.
    @Suite("LIST INBOX outside the personal namespace", .serialized, .timeLimit(.minutes(1)))
    struct ListInboxOutsideNamespaceTests {

        private func withServer(
            personalNamespacePrefix: String,
            delimiter: Character,
            mailboxNames: [String],
            body: (SwiftMail.IMAPServer, IMAPTestServer) async throws -> Void
        ) async throws {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("cur"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let testServer = try IMAPTestServer(
                username: "u", password: "p",
                personalNamespacePrefix: personalNamespacePrefix,
                namespaceDelimiter: delimiter,
                listedMailboxNames: mailboxNames,
                matchesListPatterns: true,
                maildirURL: maildir)
            try testServer.start()
            try await testServer.run {
                let server = SwiftMail.IMAPServer(
                    host: "127.0.0.1", port: testServer.port, transportSecurity: .plainText)
                try await server.connect()
                try await server.login(username: "u", password: "p")
                try await body(server, testServer)
                try await server.disconnect()
            }
        }

        private func listCommandCount(_ server: IMAPTestServer) -> Int {
            server.commandLog.filter { $0.uppercased().contains(" LIST ") }.count
        }

        @Test("Primary connection: a Mail/ prefix lists INBOX once")
        func primaryConnectionListsInbox() async throws {
            try await withServer(
                personalNamespacePrefix: "Mail/", delimiter: "/",
                mailboxNames: ["INBOX", "Mail/Sent", "Mail/Drafts"]
            ) { server, _ in
                let names = try await server.listMailboxes().map(\.name)
                #expect(names.filter { $0 == "INBOX" }.count == 1)
                #expect(Set(names) == ["INBOX", "Mail/Sent", "Mail/Drafts"])
            }
        }

        @Test("Named connection: a Mail/ prefix lists INBOX once")
        func namedConnectionListsInbox() async throws {
            try await withServer(
                personalNamespacePrefix: "Mail/", delimiter: "/",
                mailboxNames: ["INBOX", "Mail/Sent", "Mail/Drafts"]
            ) { server, _ in
                let named = try await server.connection(named: "inbox")
                let names = try await named.listMailboxes().map(\.name)
                #expect(names.filter { $0 == "INBOX" }.count == 1)
                #expect(Set(names) == ["INBOX", "Mail/Sent", "Mail/Drafts"])
            }
        }

        @Test("An INBOX. prefix lists INBOX once, with no extra LIST")
        func inboxPrefixHasNoDuplicate() async throws {
            try await withServer(
                personalNamespacePrefix: "INBOX.", delimiter: ".",
                mailboxNames: ["INBOX", "INBOX.Sent", "INBOX.Drafts"]
            ) { server, testServer in
                let names = try await server.listMailboxes().map(\.name)
                #expect(names.filter { $0 == "INBOX" }.count == 1)
                #expect(Set(names) == ["INBOX", "INBOX.Sent", "INBOX.Drafts"])
                #expect(listCommandCount(testServer) == 2)
            }
        }
    }
#endif
