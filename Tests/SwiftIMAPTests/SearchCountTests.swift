import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

/// `searchCount` asks ESEARCH only for `COUNT MIN MAX`. With `ALL` the reply for a large mailbox
/// is one long line (27 KB for 62,677 messages) that the response parser cannot buffer.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SearchCountTests {
    @Test
    func countOnlySearchOmitsAll() async throws {
        let command = ExtendedSearchCommand<SwiftMail.UID>(
            criteria: [.all],
            useEsearch: true,
            returnsAll: false
        )
        let wire = try await Self.wireFormat(of: command.toTaggedCommand(tag: "N001"))

        #expect(wire.hasPrefix("N001 UID SEARCH RETURN (COUNT MIN MAX) ALL"))
    }

    @Test
    func extendedSearchStillAsksForAll() async throws {
        let command = ExtendedSearchCommand<SwiftMail.UID>(criteria: [.all], useEsearch: true)
        let wire = try await Self.wireFormat(of: command.toTaggedCommand(tag: "N002"))

        #expect(wire.hasPrefix("N002 UID SEARCH RETURN (COUNT MIN MAX ALL) ALL"))
    }

    @Test
    func countOnlySearchWithoutEsearchIsAPlainSearch() async throws {
        let command = ExtendedSearchCommand<SwiftMail.UID>(
            criteria: [.all],
            useEsearch: false,
            returnsAll: false
        )
        let wire = try await Self.wireFormat(of: command.toTaggedCommand(tag: "N003"))

        #expect(wire.hasPrefix("N003 UID SEARCH ALL"))
        #expect(!wire.contains("RETURN"))
    }

    @Test
    func countOnlyReplyHasNoIdentifierList() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: ExtendedSearchResult<SwiftMail.UID>.self)
        let handler = ExtendedSearchHandler<SwiftMail.UID>(commandTag: "N004", promise: promise)
        try await channel.pipeline.addHandler(handler)

        let command = ExtendedSearchCommand<SwiftMail.UID>(criteria: [.all], useEsearch: true, returnsAll: false)
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(command.toTaggedCommand(tag: "N004")))
        try await channel.writeAndFlush(wrapped)
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        let reply = "* ESEARCH (TAG \"N004\") UID COUNT 62677 MIN 1 MAX 66414\r\n"
        try await channel.writeInbound(ByteBuffer(string: reply))
        try await channel.writeInbound(ByteBuffer(string: "N004 OK Search completed\r\n"))

        let result = try await promise.futureResult.get()
        #expect(result.count == 62677)
        #expect(result.min?.value == 1)
        #expect(result.max?.value == 66414)
        #expect(result.all == nil)
    }

    private static func wireFormat(of tagged: TaggedCommand) async throws -> String {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)
        var chunk = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
        return chunk.readString(length: chunk.readableBytes) ?? ""
    }
}
