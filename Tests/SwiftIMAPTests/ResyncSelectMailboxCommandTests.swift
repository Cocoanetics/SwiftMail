import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ResyncSelectMailboxCommandTests {
    @Test
    func exactWireEncoding() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let command = ResyncSelectMailboxCommand(
            mailboxName: "INBOX",
            uidValidity: 777,
            modificationSequence: 900
        )
        let tagged = command.toTaggedCommand(tag: "A002")
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(tagged)))

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        #expect(
            outbound.readString(length: outbound.readableBytes)
                == "A002 SELECT \"INBOX\" (QRESYNC (777 900))\r\n"
        )
    }

    @Test
    func validatesCheckpoint() {
        #expect(throws: IMAPError.self) {
            try ResyncSelectMailboxCommand(
                mailboxName: "",
                uidValidity: 777,
                modificationSequence: 900
            ).validate()
        }
        #expect(throws: IMAPError.self) {
            try ResyncSelectMailboxCommand(
                mailboxName: "INBOX",
                uidValidity: 0,
                modificationSequence: 900
            ).validate()
        }
        #expect(throws: IMAPError.self) {
            try ResyncSelectMailboxCommand(
                mailboxName: "INBOX",
                uidValidity: 777,
                modificationSequence: 0
            ).validate()
        }

        let outOfRange: ModificationSequenceValue = 9_223_372_036_854_775_808
        #expect(throws: IMAPError.self) {
            try ResyncSelectMailboxCommand(
                mailboxName: "INBOX",
                uidValidity: 777,
                modificationSequence: outOfRange
            ).validate()
        }
    }

    @Test
    func workedInterleavedExchange() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: Mailbox.ResyncSelection.self)
        let handler = ResyncSelectHandler(commandTag: "A002", promise: promise)
        try await channel.pipeline.addHandler(handler)

        let select = ResyncSelectMailboxCommand(
            mailboxName: "INBOX",
            uidValidity: 777,
            modificationSequence: 900
        )
        try await channel.writeAndFlush(
            IMAPClientHandler.OutboundIn.part(.tagged(select.toTaggedCommand(tag: "A002")))
        )
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        try await writeInbound(
            channel,
            "* 5 EXISTS\r\n"
                + "* 1 RECENT\r\n"
                + "* FLAGS (\\Seen \\Answered \\Flagged $Work)\r\n"
                + "* OK [UNSEEN 2] First unseen\r\n"
                + "* OK [PERMANENTFLAGS (\\Seen \\*)] Permanent\r\n"
                + "* OK [UIDVALIDITY 777] Validity\r\n"
                + "* VANISHED (EARLIER) 10:12,20\r\n"
                + "* OK [UIDNEXT 51] Next UID\r\n"
                + "* 2 FETCH (FLAGS (\\Seen $Wo"
        )
        #expect(!handler.isCompleted)
        try await writeInbound(
            channel,
            "rk) MODSEQ (901) UID 42)\r\n"
                + "* OK [HIGHESTMODSEQ 950] Highest sequence\r\n"
                + "* VANISHED (EARLIER) 12:14\r\n"
                + "* VANISHED 30:31\r\n"
                + "* 3 FETCH (UID 43 FLAGS () MODSEQ (902))\r\n"
                + "* 2 FETCH (UID 42 FLAGS (\\Answered) MODSEQ (903))\r\n"
                + "* 4 FETCH (FLAGS (\\Flagged) MODSEQ (904))\r\n"
                + "* 2 FETCH (UID 42 MODSEQ (905))\r\n"
                + "* 5 FETCH (FLAGS (\\Seen $NoModseq) UID 44)\r\n"
        )
        #expect(!handler.isCompleted)
        #expect(handler.untaggedResponses.isEmpty)
        try await writeInbound(channel, "A002 OK [READ-WRITE] Selected\r\n")

        let result = try await promise.futureResult.get()
        #expect(result.selection.messageCount == 5)
        #expect(result.selection.recentCount == 1)
        #expect(result.selection.firstUnseen == 2)
        #expect(result.selection.uidValidity == UIDValidity(777))
        #expect(result.selection.uidNext == UID(51))
        #expect(result.selection.highestModSequence == 950)
        #expect(!result.selection.isReadOnly)
        #expect(result.selection.availableFlags.map(\.description) == ["seen", "answered", "flagged", "$Work"])
        #expect(result.selection.permanentFlags.map(\.description) == ["seen", "wildcard"])
        #expect(result.vanishedEarlier.ranges == [10...14, 20...20])
        #expect(result.changedFlags[UID(42)] == [.answered])
        #expect(result.changedFlags[UID(43)] == [])
        #expect(result.changedFlags[UID(44)] == [.seen, .custom("$NoModseq")])
        #expect(result.changedFlags[UID(4)] == nil)
    }

    @Test
    func closedBoundaryResetsOldMailboxState() async throws {
        let result = try await execute(
            "* 8 EXISTS\r\n"
                + "* VANISHED (EARLIER) 1:2\r\n"
                + "* 1 FETCH (UID 10 FLAGS (\\Seen))\r\n"
                + "* OK [CLOSED] Previous mailbox closed\r\n"
                + "* 3 EXISTS\r\n"
                + "* VANISHED (EARLIER) 20:21\r\n"
                + "* 1 FETCH (UID 10 FLAGS (\\Answered))\r\n"
                + "A002 OK [READ-ONLY] Selected\r\n"
        )

        #expect(result.selection.messageCount == 3)
        #expect(result.selection.isReadOnly)
        #expect(result.vanishedEarlier.ranges == [20...21])
        #expect(result.changedFlags[UID(10)] == [.answered])
    }

    @Test
    func checkpointMetadataPreservesRangeAndNoModSequence() async throws {
        let maximum = try await execute(
            "* OK [UIDVALIDITY 999] Changed validity\r\n"
                + "* OK [HIGHESTMODSEQ 9223372036854775807] Highest\r\n"
                + "* VANISHED (EARLIER) 1000000:4000000000\r\n"
                + "A002 OK Selected\r\n"
        )
        #expect(maximum.selection.uidValidity == UIDValidity(999))
        #expect(maximum.selection.highestModSequence == ModificationSequenceValue(exactly: Int64.max))
        #expect(maximum.vanishedEarlier.ranges == [1_000_000...4_000_000_000])

        let noCheckpoint = try await execute(
            "* OK [HIGHESTMODSEQ 950] Highest\r\n"
                + "* OK [NOMODSEQ] Unavailable\r\n"
                + "A002 OK Selected\r\n"
        )
        #expect(noCheckpoint.selection.highestModSequence == nil)

        let absent = try await execute("A002 OK Selected\r\n")
        #expect(absent.selection.highestModSequence == nil)
    }

    @Test
    func unrelatedTagDoesNotCompleteHandler() async throws {
        let channel = NIOAsyncTestingChannel()
        let promise = channel.eventLoop.makePromise(of: Mailbox.ResyncSelection.self)
        let handler = ResyncSelectHandler(commandTag: "A002", promise: promise)
        let response = Response.tagged(
            TaggedResponse(tag: "Z999", state: .ok(ResponseText(text: "Other command")))
        )

        #expect(!handler.processResponse(response))
        #expect(!handler.isCompleted)
        promise.fail(IMAPError.commandFailed("Test complete"))
    }

    @Test
    func plainVanishedIsNotHistoricalDeletion() async throws {
        let result = try await execute(
            "* 5 EXISTS\r\n"
                + "* VANISHED 1:100\r\n"
                + "* VANISHED (EARLIER) 200:201\r\n"
                + "A002 OK Selected\r\n"
        )

        #expect(result.selection.messageCount == 5)
        #expect(result.vanishedEarlier.ranges == [200...201])
    }

    @Test
    func byeFailsInsteadOfReturningPartialData() async throws {
        let (channel, promise) = try await makePendingSelection()
        try await writeInbound(channel, "* 5 EXISTS\r\n* BYE Server shutting down\r\n")

        await #expect(throws: IMAPError.self) {
            _ = try await promise.futureResult.get()
        }
        try? await channel.close()
    }

    @Test
    func channelClosureFailsInsteadOfHanging() async throws {
        let (channel, promise) = try await makePendingSelection()
        try await writeInbound(channel, "* 5 EXISTS\r\n")
        try await channel.close()

        await #expect(throws: IMAPError.self) {
            _ = try await promise.futureResult.get()
        }
    }

    @Test(arguments: ["NO", "BAD"])
    func partialDataIsNotReturnedAfterRejection(_ status: String) async throws {
        await #expect(throws: IMAPError.self) {
            _ = try await execute(
                "* 5 EXISTS\r\n"
                    + "* VANISHED (EARLIER) 10:12\r\n"
                    + "A002 \(status) Rejected\r\n"
            )
        }
    }

    private func execute(_ rawResponse: String) async throws -> Mailbox.ResyncSelection {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: Mailbox.ResyncSelection.self)
        let handler = ResyncSelectHandler(commandTag: "A002", promise: promise)
        try await channel.pipeline.addHandler(handler)

        let select = ResyncSelectMailboxCommand(
            mailboxName: "INBOX",
            uidValidity: 777,
            modificationSequence: 900
        )
        try await channel.writeAndFlush(
            IMAPClientHandler.OutboundIn.part(.tagged(select.toTaggedCommand(tag: "A002")))
        )
        _ = try await channel.readOutbound(as: ByteBuffer.self)
        try await writeInbound(channel, rawResponse)
        return try await promise.futureResult.get()
    }

    private func makePendingSelection() async throws -> (
        channel: NIOAsyncTestingChannel,
        promise: EventLoopPromise<Mailbox.ResyncSelection>
    ) {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: Mailbox.ResyncSelection.self)
        let handler = ResyncSelectHandler(commandTag: "A002", promise: promise)
        try await channel.pipeline.addHandler(handler)
        let command = ResyncSelectMailboxCommand(
            mailboxName: "INBOX",
            uidValidity: 777,
            modificationSequence: 900
        )
        try await channel.writeAndFlush(
            IMAPClientHandler.OutboundIn.part(.tagged(command.toTaggedCommand(tag: "A002")))
        )
        _ = try await channel.readOutbound(as: ByteBuffer.self)
        return (channel, promise)
    }

    private func writeInbound(_ channel: NIOAsyncTestingChannel, _ text: String) async throws {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        try await channel.writeInbound(buffer)
    }
}
