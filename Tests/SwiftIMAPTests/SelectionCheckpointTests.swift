import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

enum OrdinarySelectionCommand: CaseIterable, Equatable, Sendable {
    case select
    case examine

    var tag: String {
        switch self {
            case .select: "S001"
            case .examine: "E001"
        }
    }

    var commandLine: String {
        switch self {
            case .select: "S001 SELECT \"INBOX\"\r\n"
            case .examine: "E001 EXAMINE \"Archive\"\r\n"
        }
    }

    var completionCode: String {
        switch self {
            case .select: "READ-WRITE"
            case .examine: "READ-ONLY"
        }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SelectionCheckpointTests {
    @Test
    func ordinarySelectKeepsWireFormatAndReturnsHighestModSequence() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: Mailbox.Selection.self)
        let handler = SelectHandler(commandTag: "S001", promise: promise)
        try await channel.pipeline.addHandler(handler)

        let command = SelectMailboxCommand(mailboxName: "INBOX")
        try await channel.writeAndFlush(
            IMAPClientHandler.OutboundIn.part(.tagged(command.toTaggedCommand(tag: "S001")))
        )
        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected SELECT command")
            return
        }
        #expect(outbound.readString(length: outbound.readableBytes) == "S001 SELECT \"INBOX\"\r\n")

        try await writeSelectionInbound(
            channel,
            "* 9 EXISTS\r\n"
                + "* OK [UIDVALIDITY 777] Current\r\n"
                + "* OK [HIGHESTMODSEQ 9223372036854775807] Highest\r\n"
                + "S001 OK [READ-WRITE] Selected\r\n"
        )
        let selection = try await promise.futureResult.get()
        #expect(selection.messageCount == 9)
        #expect(selection.uidValidity == UIDValidity(777))
        #expect(selection.highestModSequence == ModificationSequenceValue(exactly: Int64.max))
        #expect(!selection.isReadOnly)
        try await channel.close()
    }

    @Test
    func examineKeepsWireFormatAndReturnsReadOnlyCheckpoint() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: Mailbox.Selection.self)
        let handler = SelectHandler(commandTag: "E001", promise: promise)
        try await channel.pipeline.addHandler(handler)

        let command = ExamineMailboxCommand(mailboxName: "Archive")
        try await channel.writeAndFlush(
            IMAPClientHandler.OutboundIn.part(.tagged(command.toTaggedCommand(tag: "E001")))
        )
        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected EXAMINE command")
            return
        }
        #expect(outbound.readString(length: outbound.readableBytes) == "E001 EXAMINE \"Archive\"\r\n")

        try await writeSelectionInbound(
            channel,
            "* OK [HIGHESTMODSEQ 950] Highest\r\nE001 OK [READ-ONLY] Examined\r\n"
        )
        let selection = try await promise.futureResult.get()
        #expect(selection.highestModSequence == 950)
        #expect(selection.isReadOnly)
        try await channel.close()
    }

    @Test
    func ordinarySelectionNoModSequenceClearsCheckpoint() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: Mailbox.Selection.self)
        let handler = SelectHandler(commandTag: "S001", promise: promise)
        try await channel.pipeline.addHandler(handler)
        let command = SelectMailboxCommand(mailboxName: "INBOX")
        try await channel.writeAndFlush(
            IMAPClientHandler.OutboundIn.part(.tagged(command.toTaggedCommand(tag: "S001")))
        )
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        try await writeSelectionInbound(
            channel,
            "* OK [HIGHESTMODSEQ 950] Highest\r\n"
                + "* OK [NOMODSEQ] Unavailable\r\n"
                + "S001 OK Selected\r\n"
        )
        #expect(try await promise.futureResult.get().highestModSequence == nil)
        try await channel.close()
    }

    @Test(arguments: OrdinarySelectionCommand.allCases)
    func ordinarySelectionAppliesLiveVanished(_ command: OrdinarySelectionCommand) async throws {
        let selection = try await executeSelection(
            command,
            responses: "* 5 EXISTS\r\n* VANISHED 42\r\n"
        )

        #expect(selection.messageCount == 4)
        #expect(selection.isReadOnly == (command == .examine))
    }

    @Test
    func historicalVanishedDoesNotAffectCountOrLiveDeduplication() async throws {
        let historicalOnly = try await executeSelection(
            .select,
            responses: "* 5 EXISTS\r\n* VANISHED (EARLIER) 10:11\r\n"
        )
        #expect(historicalOnly.messageCount == 5)

        let followedByLive = try await executeSelection(
            .select,
            responses: "* 5 EXISTS\r\n* VANISHED (EARLIER) 42\r\n* VANISHED 42\r\n"
        )
        #expect(followedByLive.messageCount == 4)
    }

    @Test
    func existsAndLiveDeletionsApplyInWireOrder() async throws {
        let laterExists = try await executeSelection(
            .select,
            responses: "* 5 EXISTS\r\n* VANISHED 42\r\n* 6 EXISTS\r\n"
        )
        #expect(laterExists.messageCount == 6)

        let laterDeletion = try await executeSelection(
            .select,
            responses: "* 5 EXISTS\r\n* VANISHED 42\r\n* 6 EXISTS\r\n* VANISHED 43\r\n"
        )
        #expect(laterDeletion.messageCount == 5)
    }

    @Test
    func overlappingAndDuplicateLiveDeletionsAreCountedOnce() async throws {
        let overlapping = try await executeSelection(
            .select,
            responses: "* 5 EXISTS\r\n* VANISHED 42:43\r\n* VANISHED 43:44\r\n"
        )
        #expect(overlapping.messageCount == 2)

        let duplicate = try await executeSelection(
            .select,
            responses: "* 5 EXISTS\r\n* VANISHED 42\r\n* VANISHED 42\r\n"
        )
        #expect(duplicate.messageCount == 4)
    }

    @Test
    func largeLiveDeletionRangeClampsCountAtZero() async throws {
        let selection = try await executeSelection(
            .select,
            responses: "* 2 EXISTS\r\n* VANISHED 1:1000000000\r\n"
        )

        #expect(selection.messageCount == 0)
    }

    @Test
    func ordinarySelectClosedBoundaryResetsOldMailboxMetadata() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: Mailbox.Selection.self)
        let handler = SelectHandler(commandTag: "S001", promise: promise)
        try await channel.pipeline.addHandler(handler)
        let command = SelectMailboxCommand(mailboxName: "INBOX")
        try await channel.writeAndFlush(
            IMAPClientHandler.OutboundIn.part(.tagged(command.toTaggedCommand(tag: "S001")))
        )
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        try await writeSelectionInbound(
            channel,
            "* 8 EXISTS\r\n"
                + "* VANISHED 42\r\n"
                + "* OK [UNSEEN 7] Old unseen\r\n"
                + "* OK [UIDNEXT 999] Old next UID\r\n"
                + "* OK [HIGHESTMODSEQ 950] Old checkpoint\r\n"
                + "* OK [CLOSED] Previous mailbox closed\r\n"
                + "* 3 EXISTS\r\n"
                + "* VANISHED 42\r\n"
                + "* OK [UIDVALIDITY 777] Current\r\n"
                + "S001 OK [READ-WRITE] Selected\r\n"
        )

        let selection = try await promise.futureResult.get()
        #expect(selection.messageCount == 2)
        #expect(selection.firstUnseen == 0)
        #expect(selection.uidNext == UID(0))
        #expect(selection.highestModSequence == nil)
        #expect(selection.uidValidity == UIDValidity(777))
        try await channel.close()
    }

    @Test
    func examineClosedBoundaryResetsOldMailboxMetadata() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: Mailbox.Selection.self)
        let handler = SelectHandler(commandTag: "E001", promise: promise)
        try await channel.pipeline.addHandler(handler)
        let command = ExamineMailboxCommand(mailboxName: "Archive")
        try await channel.writeAndFlush(
            IMAPClientHandler.OutboundIn.part(.tagged(command.toTaggedCommand(tag: "E001")))
        )
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        try await writeSelectionInbound(
            channel,
            "* 5 EXISTS\r\n"
                + "* VANISHED 42\r\n"
                + "* OK [UNSEEN 7] Old unseen\r\n"
                + "* OK [UIDNEXT 999] Old next UID\r\n"
                + "* OK [HIGHESTMODSEQ 950] Old checkpoint\r\n"
                + "* OK [CLOSED] Previous mailbox closed\r\n"
                + "* 3 EXISTS\r\n"
                + "* VANISHED 42\r\n"
                + "E001 OK [READ-ONLY] Examined\r\n"
        )

        let selection = try await promise.futureResult.get()
        #expect(selection.messageCount == 2)
        #expect(selection.firstUnseen == 0)
        #expect(selection.uidNext == UID(0))
        #expect(selection.highestModSequence == nil)
        #expect(selection.isReadOnly)
        try await channel.close()
    }

    @Test(arguments: ["NO", "BAD"])
    func rejectedOrdinarySelectionDoesNotReturnPartialState(_ status: String) async throws {
        await #expect(throws: IMAPError.self) {
            _ = try await executeSelection(
                .select,
                responses: "* 5 EXISTS\r\n* VANISHED 42\r\n",
                completionStatus: status
            )
        }
    }

    private func executeSelection(
        _ command: OrdinarySelectionCommand,
        responses: String,
        completionStatus: String = "OK"
    ) async throws -> Mailbox.Selection {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: Mailbox.Selection.self)
        let handler = SelectHandler(commandTag: command.tag, promise: promise)
        try await channel.pipeline.addHandler(handler)

        switch command {
            case .select:
                let select = SelectMailboxCommand(mailboxName: "INBOX")
                try await channel.writeAndFlush(
                    IMAPClientHandler.OutboundIn.part(.tagged(select.toTaggedCommand(tag: command.tag)))
                )
            case .examine:
                let examine = ExamineMailboxCommand(mailboxName: "Archive")
                try await channel.writeAndFlush(
                    IMAPClientHandler.OutboundIn.part(.tagged(examine.toTaggedCommand(tag: command.tag)))
                )
        }

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected ordinary selection command")
            throw IMAPError.commandFailed("Expected ordinary selection command")
        }
        #expect(outbound.readString(length: outbound.readableBytes) == command.commandLine)

        let completion = "\(command.tag) \(completionStatus) [\(command.completionCode)] Selected\r\n"
        try await writeSelectionInbound(channel, responses + completion)
        let selection = try await promise.futureResult.get()
        try await channel.close()
        return selection
    }
}

private func writeSelectionInbound(_ channel: NIOAsyncTestingChannel, _ text: String) async throws {
    var buffer = channel.allocator.buffer(capacity: text.utf8.count)
    buffer.writeString(text)
    try await channel.writeInbound(buffer)
}
