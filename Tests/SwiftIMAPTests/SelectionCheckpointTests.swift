import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

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
                + "* OK [UNSEEN 7] Old unseen\r\n"
                + "* OK [UIDNEXT 999] Old next UID\r\n"
                + "* OK [HIGHESTMODSEQ 950] Old checkpoint\r\n"
                + "* OK [CLOSED] Previous mailbox closed\r\n"
                + "* 3 EXISTS\r\n"
                + "* OK [UIDVALIDITY 777] Current\r\n"
                + "S001 OK [READ-WRITE] Selected\r\n"
        )

        let selection = try await promise.futureResult.get()
        #expect(selection.messageCount == 3)
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
            "* OK [UNSEEN 7] Old unseen\r\n"
                + "* OK [UIDNEXT 999] Old next UID\r\n"
                + "* OK [HIGHESTMODSEQ 950] Old checkpoint\r\n"
                + "* OK [CLOSED] Previous mailbox closed\r\n"
                + "E001 OK [READ-ONLY] Examined\r\n"
        )

        let selection = try await promise.futureResult.get()
        #expect(selection.firstUnseen == 0)
        #expect(selection.uidNext == UID(0))
        #expect(selection.highestModSequence == nil)
        #expect(selection.isReadOnly)
        try await channel.close()
    }
}

private func writeSelectionInbound(_ channel: NIOAsyncTestingChannel, _ text: String) async throws {
    var buffer = channel.allocator.buffer(capacity: text.utf8.count)
    buffer.writeString(text)
    try await channel.writeInbound(buffer)
}
