import Testing
import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAPCore
@testable import SwiftMail

/// Do `FetchReceiveLimits` stop a metadata FETCH from growing while its replies arrive?
///
/// These tests drive `FetchMessageInfoHandler` directly, so they can see what it keeps and what
/// it passes on once a limit is reached.
@Suite("Metadata FETCH receive limits", .timeLimit(.minutes(1)))
struct FetchReceiveLimitsTests {

    private struct Harness {
        let channel: EmbeddedChannel
        let result: EventLoopFuture<[MessageInfo]>
    }

    /// - Note: Connected first, so `isActive == false` afterwards means the handler closed it.
    private func makeHarness(_ limits: FetchReceiveLimits) throws -> Harness {
        try makeHarness(budget: try #require(try FetchReceiveBudget.make(for: limits)))
    }

    private func makeHarness(budget: FetchReceiveBudget) throws -> Harness {
        let channel = EmbeddedChannel()
        let promise = channel.embeddedEventLoop.makePromise(of: [MessageInfo].self)
        try channel.pipeline.syncOperations.addHandler(
            FetchMessageInfoHandler(commandTag: "A1", promise: promise, budget: budget)
        )
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 993)).wait()
        #expect(channel.isActive, "Precondition: the channel has to be open for a close to mean anything")
        return Harness(channel: channel, result: promise.futureResult)
    }

    /// One FETCH reply, with a streamed `BODY[TEXT]` section of `sectionSize` bytes when given.
    private func reply(_ number: UInt32, sectionSize: Int? = nil) -> [Response] {
        var responses: [Response] = [
            .fetch(.start(NIOIMAPCore.SequenceNumber(rawValue: number))),
            .fetch(.simpleAttribute(.uid(NIOIMAPCore.UID(rawValue: number))))
        ]
        if let sectionSize {
            responses += [
                .fetch(.streamingBegin(kind: .rfc822Text, byteCount: sectionSize)),
                .fetch(.streamingBytes(ByteBuffer(repeating: UInt8(ascii: "x"), count: sectionSize))),
                .fetch(.streamingEnd)
            ]
        }
        return responses + [.fetch(.finish)]
    }

    private let taggedOK = Response.tagged(TaggedResponse(tag: "A1", state: .ok(ResponseText(text: "FETCH done"))))

    private func write(_ responses: [Response], to channel: EmbeddedChannel) throws {
        for response in responses {
            try channel.writeInbound(response)
        }
    }

    /// The settled result, or `nil` while the handler is still waiting.
    private func outcome(_ future: EventLoopFuture<[MessageInfo]>) -> Result<[MessageInfo], Error>? {
        var outcome: Result<[MessageInfo], Error>?
        future.whenComplete { outcome = $0 }
        return outcome
    }

    private func failure(_ future: EventLoopFuture<[MessageInfo]>) -> Error? {
        guard case .failure(let error) = outcome(future) else { return nil }
        return error
    }

    private func forwardedCount(_ channel: EmbeddedChannel) throws -> Int {
        var count = 0
        while try channel.readInbound(as: Response.self) != nil { count += 1 }
        return count
    }

    @Test("Exactly the reply limit is allowed")
    func exactReplyLimit() throws {
        let harness = try makeHarness(FetchReceiveLimits(maximumReplies: 3))
        try write(reply(1) + reply(2) + reply(3) + [taggedOK], to: harness.channel)

        let infos = try #require(try outcome(harness.result)?.get())
        #expect(infos.map(\.uid) == [SwiftMail.UID(1), SwiftMail.UID(2), SwiftMail.UID(3)])
        #expect(harness.channel.isActive)
    }

    /// 🔴 The reply one past the limit fails the call and closes the connection; nothing after it
    /// is kept, passed on, or able to turn the failure into a success.
    @Test("One reply past the limit fails closed and stops reading")
    func replyOverflowFailsClosed() throws {
        let harness = try makeHarness(FetchReceiveLimits(maximumReplies: 3))
        try write(reply(1) + reply(2) + reply(3), to: harness.channel)
        let forwardedBeforeLimit = try forwardedCount(harness.channel)
        try write(reply(4), to: harness.channel)

        let error = try #require(failure(harness.result), "A FETCH past its limit must not succeed")
        #expect(error as? FetchReceiveLimitExceededError
            == FetchReceiveLimitExceededError(dimension: .replies, limit: 3, attemptedUsage: 4))
        #expect(harness.channel.isActive == false, "A limit violation has to close the connection")
        #expect(IMAPResponseLimitGuard.isLimitViolation(error))

        _ = try? harness.channel.writeInbound(taggedOK)
        #expect(try forwardedCount(harness.channel) == 0, "Nothing from the rejected reply on is passed on")
        #expect(forwardedBeforeLimit == 9)
        #expect(failure(harness.result) != nil, "A late tagged OK must not complete the call a second time")
    }

    @Test("Exactly the payload limit is allowed, counting sections that are not kept")
    func exactPayloadLimit() throws {
        let harness = try makeHarness(FetchReceiveLimits(maximumPayloadBytes: 30))
        try write(reply(1, sectionSize: 10) + reply(2, sectionSize: 20) + [taggedOK], to: harness.channel)

        #expect(try #require(try outcome(harness.result)?.get()).count == 2)
        #expect(harness.channel.isActive)
    }

    @Test("One byte past the payload limit fails closed at the section's declaration")
    func payloadOverflowFailsClosed() throws {
        let harness = try makeHarness(FetchReceiveLimits(maximumPayloadBytes: 29))
        try write(reply(1, sectionSize: 10), to: harness.channel)
        try write(reply(2, sectionSize: 20), to: harness.channel)

        let error = try #require(failure(harness.result))
        #expect(error as? FetchReceiveLimitExceededError
            == FetchReceiveLimitExceededError(dimension: .payloadBytes, limit: 29, attemptedUsage: 30))
        #expect(harness.channel.isActive == false)
    }

    @Test("Zero limits allow nothing of that dimension")
    func zeroLimits() throws {
        let noReplies = try makeHarness(FetchReceiveLimits(maximumReplies: 0))
        try write(reply(1), to: noReplies.channel)
        #expect(failure(noReplies.result) as? FetchReceiveLimitExceededError
            == FetchReceiveLimitExceededError(dimension: .replies, limit: 0, attemptedUsage: 1))

        let emptySections = try makeHarness(FetchReceiveLimits(maximumPayloadBytes: 0))
        try write(reply(1, sectionSize: 0) + [taggedOK], to: emptySections.channel)
        #expect(try outcome(emptySections.result)?.get().count == 1)
    }

    @Test("Payload sums use checked arithmetic")
    func payloadOverflowArithmetic() throws {
        let harness = try makeHarness(FetchReceiveLimits(maximumPayloadBytes: .max))
        for number: UInt32 in 1...3 {
            try write([
                .fetch(.start(NIOIMAPCore.SequenceNumber(rawValue: number))),
                .fetch(.streamingBegin(kind: .rfc822Text, byteCount: .max))
            ], to: harness.channel)
        }
        #expect(failure(harness.result) as? FetchReceiveLimitExceededError
            == FetchReceiveLimitExceededError(dimension: .payloadBytes, limit: .max, attemptedUsage: .max))
    }

    /// The chunks of one call share a budget: each stays under the limit, together they do not.
    @Test("Commands sharing a budget are limited together")
    func sharedBudgetSpansCommands() throws {
        let budget = try #require(try FetchReceiveBudget.make(for: FetchReceiveLimits(maximumReplies: 3)))

        let first = try makeHarness(budget: budget)
        try write(reply(1) + reply(2) + [taggedOK], to: first.channel)
        #expect(try outcome(first.result)?.get().count == 2)

        let second = try makeHarness(budget: budget)
        try write(reply(3) + reply(4), to: second.channel)
        #expect(failure(second.result) as? FetchReceiveLimitExceededError
            == FetchReceiveLimitExceededError(dimension: .replies, limit: 3, attemptedUsage: 4))
        #expect(second.channel.isActive == false)
    }

    @Test("Negative reply limits are rejected and no limits need no budget")
    func validation() throws {
        #expect(throws: IMAPError.self) {
            try FetchReceiveBudget.make(for: FetchReceiveLimits(maximumReplies: -1))
        }
        #expect(try FetchReceiveBudget.make(for: .unlimited) == nil)
        #expect(FetchReceiveLimits() == .unlimited)
    }
}

#if os(macOS)
    /// The same limits end to end, on primary and named connections.
    @Suite("Metadata FETCH receive limits over a connection", .serialized, .timeLimit(.minutes(1)))
    struct FetchReceiveLimitsIntegrationTests {

        /// Every message has a header of the same length.
        private static func header(_ number: Int) -> String {
            "From: a@example.com\r\nSubject: Message \(number)\r\n\r\n"
        }

        private static let headerSize = UInt64(Data(header(1).utf8).count)

        private static let fourthReply = FetchReceiveLimitExceededError(
            dimension: .replies, limit: 3, attemptedUsage: 4
        )

        private func withServer(
            messageCount: Int,
            body: (SwiftMail.IMAPServer, IMAPTestServer) async throws -> Void
        ) async throws {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("cur"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("new"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            for number in 1...messageCount {
                try Data((Self.header(number) + "Hello\r\n").utf8)
                    .write(to: maildir.appendingPathComponent("cur/\(number).eml"))
            }

            let testServer = try IMAPTestServer(maildirURL: maildir)
            try testServer.start()
            try await testServer.run {
                let server = SwiftMail.IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()
                try await server.login(username: "testuser", password: "testpass")
                _ = try await server.selectMailbox("INBOX")
                try await body(server, testServer)
                try await server.disconnect()
            }
        }

        private func uids(_ range: ClosedRange<UInt32>) -> ClosedRange<SwiftMail.UID> {
            SwiftMail.UID(range.lowerBound)...SwiftMail.UID(range.upperBound)
        }

        @Test("Primary connection: reply limit is a maximum, one more fails and closes the connection")
        func primaryReplies() async throws {
            try await withServer(messageCount: 4) { server, testServer in
                let limits = FetchReceiveLimits(maximumReplies: 3)
                let infos = try await server.fetchMessageInfos(uidRange: uids(1...3), limits: limits)
                #expect(infos.count == 3)

                await #expect(throws: Self.fourthReply) {
                    try await server.fetchMessageInfos(uidRange: uids(1...4), limits: limits)
                }
                #expect(testServer.acceptedConnectionCount == 1)

                // The connection was closed; the next command reconnects and works.
                _ = try await server.selectMailbox("INBOX")
                #expect(testServer.acceptedConnectionCount == 2)
                #expect(try await server.fetchMessageInfosBulk(using: SwiftMail.UIDSet(uids(1...4))).count == 4)
            }
        }

        @Test("Primary connection: payload limit is a maximum, one byte less fails")
        func primaryPayload() async throws {
            try await withServer(messageCount: 3) { server, _ in
                let total = 3 * Self.headerSize
                let infos = try await server.fetchMessageInfosBulk(
                    using: SwiftMail.UIDSet(uids(1...3)), options: [.fullHeader],
                    limits: FetchReceiveLimits(maximumPayloadBytes: total))
                #expect(infos.map(\.subject) == ["Message 1", "Message 2", "Message 3"])

                await #expect(throws: FetchReceiveLimitExceededError(
                    dimension: .payloadBytes, limit: total - 1, attemptedUsage: total
                )) {
                    try await server.fetchMessageInfosBulk(
                        using: SwiftMail.UIDSet(uids(1...3)), options: [.fullHeader],
                        limits: FetchReceiveLimits(maximumPayloadBytes: total - 1))
                }
            }
        }

        @Test("Named connection: limits close only that connection")
        func namedConnection() async throws {
            try await withServer(messageCount: 4) { server, testServer in
                let named = try await server.connection(named: "limited")
                _ = try await named.selectMailbox("INBOX")
                #expect(testServer.acceptedConnectionCount == 2)

                let replies = FetchReceiveLimits(maximumReplies: 3)
                #expect(try await named.fetchMessageInfos(uidRange: uids(1...3), limits: replies).count == 3)
                await #expect(throws: Self.fourthReply) {
                    try await named.fetchMessageInfosBulk(using: SwiftMail.UIDSet(uids(1...4)), limits: replies)
                }

                // The primary connection is untouched.
                #expect(try await server.fetchMessageInfosBulk(using: SwiftMail.UIDSet(uids(1...4))).count == 4)
                #expect(testServer.acceptedConnectionCount == 2)

                _ = try await named.selectMailbox("INBOX")
                #expect(testServer.acceptedConnectionCount == 3)
                let total = 4 * Self.headerSize
                let infos = try await named.fetchMessageInfosBulk(
                    using: SwiftMail.UIDSet(uids(1...4)), options: [.fullHeader],
                    limits: FetchReceiveLimits(maximumPayloadBytes: total))
                #expect(infos.count == 4)
                await #expect(throws: FetchReceiveLimitExceededError(
                    dimension: .payloadBytes, limit: total - 1, attemptedUsage: total
                )) {
                    try await named.fetchMessageInfosBulk(
                        using: SwiftMail.UIDSet(uids(1...4)), options: [.fullHeader],
                        limits: FetchReceiveLimits(maximumPayloadBytes: total - 1))
                }
            }
        }

        /// Six messages in chunks of two: the second chunk goes past three replies, and the third
        /// chunk is never sent.
        @Test("A stream's chunks share one budget")
        func streamSharesBudget() async throws {
            try await withServer(messageCount: 6) { server, testServer in
                let set = SwiftMail.UIDSet(uids(1...6))
                var all: [MessageInfo] = []
                for try await info in server.fetchMessageInfos(
                    using: set, chunkSize: 2, limits: FetchReceiveLimits(maximumReplies: 6)
                ) {
                    all.append(info)
                }
                #expect(all.count == 6)

                _ = try await server.selectMailbox("INBOX")
                let fetchesBefore = testServer.commandLog.filter { $0.contains("FETCH") }.count
                var yielded: [SwiftMail.UID?] = []
                await #expect(throws: Self.fourthReply) {
                    for try await info in server.fetchMessageInfos(
                        using: set, chunkSize: 2, limits: FetchReceiveLimits(maximumReplies: 3)
                    ) {
                        yielded.append(info.uid)
                    }
                }
                #expect(yielded == [SwiftMail.UID(1), SwiftMail.UID(2)])
                #expect(testServer.commandLog.filter { $0.contains("FETCH") }.count - fetchesBefore == 2)
            }
        }

        @Test("Overloads without limits stay unbounded, and each call gets a fresh budget")
        func defaultOverloads() async throws {
            try await withServer(messageCount: 5) { server, _ in
                let set = SwiftMail.UIDSet(uids(1...5))
                let bulk = try await server.fetchMessageInfosBulk(using: set)
                let ranged = try await server.fetchMessageInfos(uidRange: uids(1...5))
                let single = try await server.fetchMessageInfo(for: SwiftMail.UID(1))
                #expect(bulk.count == 5 && ranged.count == 5 && single != nil)

                let limits = FetchReceiveLimits(maximumReplies: 5)
                let first = try await server.fetchMessageInfosBulk(using: set, limits: limits)
                let second = try await server.fetchMessageInfosBulk(using: set, limits: limits)
                let limitedSingle = try await server.fetchMessageInfo(for: SwiftMail.UID(1), limits: limits)
                #expect(first.count == 5 && second.count == 5 && limitedSingle != nil)

                await #expect(throws: IMAPError.self) {
                    try await server.fetchMessageInfosBulk(using: set, limits: FetchReceiveLimits(maximumReplies: -1))
                }
            }
        }
    }
#endif
