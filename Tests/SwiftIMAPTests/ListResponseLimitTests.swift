import Testing
import Foundation
import NIO
import NIOEmbedded
import NIOIMAPCore
@testable import SwiftMail

/// Does `maximumListResponses` stop a listing from growing while the responses arrive?
///
/// A server can send any number of small, valid LIST responses. Checking the returned array
/// afterwards bounds nothing: by then every response is already in memory. These tests drive
/// `ListCommandHandler` directly with the sequence a hostile server would send, so they can see
/// what it keeps and what it passes on after the limit is reached.
@Suite("LIST response limit", .timeLimit(.minutes(1)))
struct ListResponseLimitTests {

    private struct Harness {
        let channel: EmbeddedChannel
        let result: EventLoopFuture<[Mailbox.Info]>
    }

    /// - Note: Connected first, so `isActive == false` afterwards means the handler closed it.
    private func makeHarness(budget: ListResponseBudget) throws -> Harness {
        let channel = EmbeddedChannel()
        let promise = channel.embeddedEventLoop.makePromise(of: [Mailbox.Info].self)
        try channel.pipeline.syncOperations.addHandler(
            ListCommandHandler(commandTag: "A1", promise: promise, budget: budget)
        )
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 993)).wait()
        #expect(channel.isActive, "Precondition: the channel has to be open for a close to mean anything")
        return Harness(channel: channel, result: promise.futureResult)
    }

    private func list(_ name: String) throws -> Response {
        let path = try MailboxPath(name: MailboxName(ByteBuffer(string: name)), pathSeparator: "/")
        return .untagged(.mailboxData(.list(MailboxInfo(attributes: [], path: path, extensions: [:]))))
    }

    private let taggedOK = Response.tagged(TaggedResponse(tag: "A1", state: .ok(ResponseText(text: "LIST done"))))

    /// The settled result, or `nil` while the handler is still waiting.
    private func outcome(_ future: EventLoopFuture<[Mailbox.Info]>) -> Result<[Mailbox.Info], Error>? {
        var outcome: Result<[Mailbox.Info], Error>?
        future.whenComplete { outcome = $0 }
        return outcome
    }

    private func forwardedCount(_ channel: EmbeddedChannel) throws -> Int {
        var count = 0
        while try channel.readInbound(as: Response.self) != nil { count += 1 }
        return count
    }

    @Test("A listing below the limit succeeds")
    func belowLimit() throws {
        let harness = try makeHarness(budget: ListResponseBudget(maximumCount: 3))
        try harness.channel.writeInbound(list("A"))
        try harness.channel.writeInbound(list("B"))
        try harness.channel.writeInbound(taggedOK)

        let names = try #require(try outcome(harness.result)?.get()).map(\.name)
        #expect(names == ["A", "B"])
        #expect(harness.channel.isActive)
    }

    @Test("Exactly the limit is still allowed")
    func exactLimit() throws {
        let harness = try makeHarness(budget: ListResponseBudget(maximumCount: 3))
        for name in ["A", "B", "C"] {
            try harness.channel.writeInbound(list(name))
        }
        try harness.channel.writeInbound(taggedOK)

        let names = try #require(try outcome(harness.result)?.get()).map(\.name)
        #expect(names == ["A", "B", "C"])
        #expect(harness.channel.isActive)
    }

    /// 🔴 The response one past the limit fails the listing and closes the connection; nothing
    /// after it is kept, passed on, or able to turn the failure into a success.
    @Test("One past the limit fails closed and stops reading")
    func overflowFailsClosed() throws {
        let harness = try makeHarness(budget: ListResponseBudget(maximumCount: 3))
        for name in ["A", "B", "C", "D"] {
            try harness.channel.writeInbound(list(name))
        }

        guard case .failure(let error) = try #require(outcome(harness.result)) else {
            Issue.record("A listing past its limit must not succeed")
            return
        }
        #expect(error as? ExceededListResponseLimitError
            == ExceededListResponseLimitError(receivedCount: 4, maximumCount: 3))
        #expect(harness.channel.isActive == false, "A limit violation has to close the connection")
        #expect(IMAPResponseLimitGuard.isLimitViolation(error))

        // Responses the same read already decoded still reach the handler; they are dropped.
        _ = try? harness.channel.writeInbound(list("E"))
        _ = try? harness.channel.writeInbound(taggedOK)
        #expect(try forwardedCount(harness.channel) == 3, "Only the responses within the limit pass on")
        guard case .failure = try #require(outcome(harness.result)) else {
            Issue.record("A late tagged OK must not complete the listing a second time")
            return
        }
    }

    @Test("Duplicate responses count toward the limit")
    func duplicatesCount() throws {
        let harness = try makeHarness(budget: ListResponseBudget(maximumCount: 3))
        for _ in 0..<4 {
            try harness.channel.writeInbound(list("INBOX"))
        }

        guard case .failure(let error) = try #require(outcome(harness.result)) else {
            Issue.record("Repeating one mailbox must not get around the limit")
            return
        }
        #expect(error is ExceededListResponseLimitError)
    }

    /// The per-namespace commands of one listing share a budget: each stays under the limit,
    /// together they do not.
    @Test("Commands sharing a budget are limited together")
    func sharedBudgetSpansCommands() throws {
        let budget = ListResponseBudget(maximumCount: 3)

        let first = try makeHarness(budget: budget)
        try first.channel.writeInbound(list("A"))
        try first.channel.writeInbound(list("B"))
        try first.channel.writeInbound(taggedOK)
        #expect(try outcome(first.result)?.get().count == 2)

        let second = try makeHarness(budget: budget)
        try second.channel.writeInbound(list("C"))
        try second.channel.writeInbound(list("D"))

        guard case .failure(let error) = try #require(outcome(second.result)) else {
            Issue.record("The second command must see what the first one used")
            return
        }
        #expect(error as? ExceededListResponseLimitError
            == ExceededListResponseLimitError(receivedCount: 4, maximumCount: 3))
        #expect(second.channel.isActive == false)
    }

    @Test("Limits default to unbounded listings")
    func defaultIsUnbounded() {
        #expect(IMAPParserLimits.default.maximumListResponses == Int.max)
        #expect(IMAPParserLimits(maximumListResponses: 1000) != IMAPParserLimits.default)
    }
}

#if os(macOS)
    /// The same limit end to end, against a server that sends every LIST response in one write.
    @Suite("LIST response limit over a connection", .serialized, .timeLimit(.minutes(1)))
    struct ListResponseLimitIntegrationTests {

        private func withServer(
            mailboxNames: [String],
            maximumListResponses: Int = .max,
            capabilities: [String] = ["IMAP4rev1", "AUTH=PLAIN", "NAMESPACE"],
            personalNamespacePrefix: String = "",
            body: (SwiftMail.IMAPServer) async throws -> Void
        ) async throws {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("cur"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let testServer = try IMAPTestServer(
                username: "u", password: "p",
                advertisedCapabilities: capabilities,
                personalNamespacePrefix: personalNamespacePrefix,
                namespaceDelimiter: ".",
                listedMailboxNames: mailboxNames,
                maildirURL: maildir)
            try testServer.start()
            try await testServer.run {
                let server = SwiftMail.IMAPServer(
                    host: "127.0.0.1", port: testServer.port, transportSecurity: .plainText,
                    parserLimits: IMAPParserLimits(maximumListResponses: maximumListResponses))
                try await server.connect()
                try await server.login(username: "u", password: "p")
                try await body(server)
                try await server.disconnect()
            }
        }

        private func names(_ count: Int) -> [String] {
            (1...count).map { "Folder\($0)" }
        }

        @Test("Primary connection: the limit is a maximum, one more fails")
        func primaryConnection() async throws {
            try await withServer(mailboxNames: names(10), maximumListResponses: 10) { server in
                let mailboxes = try await server.listMailboxes()
                #expect(mailboxes.count == 10)
            }
            try await withServer(mailboxNames: names(11), maximumListResponses: 10) { server in
                await #expect(throws: ExceededListResponseLimitError(receivedCount: 11, maximumCount: 10)) {
                    try await server.listMailboxes()
                }
                // The connection was closed; the next command reconnects and works.
                _ = try await server.selectMailbox("INBOX")
            }
        }

        @Test("Named connection enforces the same limit")
        func namedConnection() async throws {
            try await withServer(mailboxNames: names(10), maximumListResponses: 10) { server in
                let named = try await server.connection(named: "limited")
                #expect(try await named.listMailboxes().count == 10)
            }
            try await withServer(mailboxNames: names(11), maximumListResponses: 10) { server in
                let named = try await server.connection(named: "limited")
                await #expect(throws: ExceededListResponseLimitError(receivedCount: 11, maximumCount: 10)) {
                    try await named.listMailboxes()
                }
            }
        }

        /// The `INBOX.` namespace makes one listing send two LIST commands, each answered with
        /// the same three names: six responses, three mailboxes after deduplication.
        @Test("Namespace patterns of one listing share the limit, counted before deduplication")
        func namespaceAggregate() async throws {
            try await withServer(
                mailboxNames: names(3), maximumListResponses: 6, personalNamespacePrefix: "INBOX."
            ) { server in
                let mailboxes = try await server.listMailboxes()
                #expect(mailboxes.count == 3)
            }
            try await withServer(
                mailboxNames: names(3), maximumListResponses: 5, personalNamespacePrefix: "INBOX."
            ) { server in
                await #expect(throws: ExceededListResponseLimitError(receivedCount: 6, maximumCount: 5)) {
                    try await server.listMailboxes()
                }
                let named = try await server.connection(named: "limited")
                await #expect(throws: ExceededListResponseLimitError(receivedCount: 6, maximumCount: 5)) {
                    try await named.listMailboxes()
                }
            }
        }

        /// The SPECIAL-USE listing is a separate server listing with its own budget.
        @Test("Special-use detection gives each listing its own budget")
        func specialUseBudgetPerListing() async throws {
            try await withServer(
                mailboxNames: names(10), maximumListResponses: 10,
                capabilities: ["IMAP4rev1", "AUTH=PLAIN", "NAMESPACE", "SPECIAL-USE"]
            ) { server in
                _ = try await server.listSpecialUseMailboxes()
            }
        }

        @Test("Without a limit, large listings are unchanged")
        func defaultUnbounded() async throws {
            try await withServer(mailboxNames: names(2000)) { server in
                let mailboxes = try await server.listMailboxes()
                #expect(mailboxes.count == 2000)
            }
        }
    }
#endif
