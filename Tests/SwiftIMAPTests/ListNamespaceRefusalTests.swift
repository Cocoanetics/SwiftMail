import Testing
import Foundation
import NIO
import NIOEmbedded
import NIOIMAPCore
@testable import SwiftMail

/// A server may refuse the LIST pattern of a namespace other than the personal one.
///
/// Zimbra announces `(("/home/" "/"))` as "Other Users" and answers `LIST "" "/home/*"` with
/// `NO LIST failed: wildcards not permitted in username`. That must not fail the whole listing,
/// while a refused personal pattern still does.
@Suite("LIST namespace refusal", .timeLimit(.minutes(1)))
struct ListNamespaceRefusalTests {

    @Test("A tagged NO carries the server text into the error")
    func handlerKeepsServerText() throws {
        let channel = EmbeddedChannel()
        let promise = channel.embeddedEventLoop.makePromise(of: [Mailbox.Info].self)
        try channel.pipeline.syncOperations.addHandler(
            ListCommandHandler(commandTag: "A1", promise: promise)
        )
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 993)).wait()

        let text = "LIST failed: wildcards not permitted in username"
        try channel.writeInbound(
            Response.tagged(TaggedResponse(tag: "A1", state: .no(ResponseText(text: text)))))

        var outcome: Result<[Mailbox.Info], Error>?
        promise.futureResult.whenComplete { outcome = $0 }
        guard case .failure(let error) = try #require(outcome) else {
            Issue.record("A tagged NO must fail the listing")
            return
        }
        guard case IMAPError.commandFailed(let message) = error else {
            Issue.record("Expected IMAPError.commandFailed, got \(error)")
            return
        }
        #expect(message.contains(text))
    }
}

#if os(macOS)
    @Suite("LIST namespace refusal over a connection", .serialized, .timeLimit(.minutes(1)))
    struct ListNamespaceRefusalIntegrationTests {

        private static let reason = "LIST failed: wildcards not permitted in username"

        /// The server announces `/home/` as "Other Users" and refuses `refusedPatterns`.
        private func withServer(
            refusedPatterns: [String],
            body: (SwiftMail.IMAPServer) async throws -> Void
        ) async throws {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("cur"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let testServer = try IMAPTestServer(
                username: "u", password: "p",
                listedMailboxNames: ["INBOX", "Sent"],
                otherUsersNamespacePrefix: "/home/",
                refusedListPatterns: Dictionary(uniqueKeysWithValues: refusedPatterns.map { ($0, Self.reason) }),
                maildirURL: maildir)
            try testServer.start()
            try await testServer.run {
                let server = SwiftMail.IMAPServer(
                    host: "127.0.0.1", port: testServer.port, transportSecurity: .plainText)
                try await server.connect()
                try await server.login(username: "u", password: "p")
                try await body(server)
                try await server.disconnect()
            }
        }

        /// The refusal reaches the caller as `commandFailed` with the server's reason.
        private static func isRefusal(_ error: any Error) -> Bool {
            guard case IMAPError.commandFailed(let message) = error else { return false }
            return message.contains(reason)
        }

        /// What the client sends for the "Other Users" namespace `/home/` and wildcard `*`.
        private let otherUsersPatterns = ["/home/*", "/home"]

        @Test("Primary connection: a refused Other Users pattern is skipped")
        func primaryConnectionSkipsRefusedPattern() async throws {
            try await withServer(refusedPatterns: otherUsersPatterns) { server in
                let names = try await server.listMailboxes().map(\.name)
                #expect(names == ["INBOX", "Sent"])
            }
        }

        @Test("Named connection: a refused Other Users pattern is skipped")
        func namedConnectionSkipsRefusedPattern() async throws {
            try await withServer(refusedPatterns: otherUsersPatterns) { server in
                let named = try await server.connection(named: "refusal")
                let names = try await named.listMailboxes().map(\.name)
                #expect(names == ["INBOX", "Sent"])
            }
        }

        @Test("Primary connection: a refused personal pattern still fails")
        func primaryConnectionFailsOnPersonalPattern() async throws {
            try await withServer(refusedPatterns: ["*"]) { server in
                await #expect(performing: { try await server.listMailboxes() }, throws: Self.isRefusal)
            }
        }

        @Test("Named connection: a refused personal pattern still fails")
        func namedConnectionFailsOnPersonalPattern() async throws {
            try await withServer(refusedPatterns: ["*"]) { server in
                let named = try await server.connection(named: "refusal")
                await #expect(performing: { try await named.listMailboxes() }, throws: Self.isRefusal)
            }
        }
    }
#endif
