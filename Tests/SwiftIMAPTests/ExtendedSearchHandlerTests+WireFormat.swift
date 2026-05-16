import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

private typealias UID = SwiftMail.UID
private typealias SequenceNumber = SwiftMail.SequenceNumber

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ExtendedSearchHandlerWireFormatTests {

    // MARK: - Command wire format

    @Test
    func testCommandWireFormatWithEsearch() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let command = ExtendedSearchCommand<UID>(criteria: [SearchCriteria.all], useEsearch: true)
        let tagged = command.toTaggedCommand(tag: "C001")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wireString.contains("UID SEARCH"))
        #expect(wireString.contains("RETURN"))
        #expect(wireString.contains("COUNT"))
        #expect(wireString.contains("MIN"))
        #expect(wireString.contains("MAX"))
        #expect(wireString.contains("ALL"))
    }

    @Test
    func testSortedCommandWireFormatUsesUIDSort() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let command = ExtendedSearchCommand<UID>(
            criteria: [SearchCriteria.all],
            sortCriteria: [.descending(.date)],
            useSort: true,
            useEsearch: false
        )
        let tagged = command.toTaggedCommand(tag: "C001A")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wireString.contains("UID SORT"))
        #expect(wireString.contains("(REVERSE DATE)"))
        #expect(wireString.contains("UTF-8"))
        #expect(!wireString.contains("RETURN"))
    }

    @Test
    func testCommandWireFormatWithoutEsearch() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let command = ExtendedSearchCommand<UID>(criteria: [SearchCriteria.all], useEsearch: false)
        let tagged = command.toTaggedCommand(tag: "C002")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wireString.contains("UID SEARCH"))
        #expect(!wireString.contains("RETURN"))
    }

    @Test
    func testCommandWireFormatSequenceNumberWithEsearch() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let command = ExtendedSearchCommand<SequenceNumber>(criteria: [SearchCriteria.all], useEsearch: true)
        let tagged = command.toTaggedCommand(tag: "C003")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(!wireString.contains("UID SEARCH"))
        #expect(wireString.contains("SEARCH"))
        #expect(wireString.contains("RETURN"))
    }

    @Test
    func testIdentifierSetScopeIsIncludedInUIDSearch() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let ids = MessageIdentifierSet<UID>([UID(1), UID(2), UID(3)])
        let command = ExtendedSearchCommand<UID>(identifierSet: ids, criteria: [SearchCriteria.all], useEsearch: true)
        let tagged = command.toTaggedCommand(tag: "C005")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wireString.contains("UID SEARCH"))
        #expect(wireString.contains("UID 1:3") || wireString.contains("UID 1,2,3"))
    }

    @Test
    func testNoIdentifierSetSearchesEntireMailbox() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let command = ExtendedSearchCommand<UID>(identifierSet: nil, criteria: [SearchCriteria.all], useEsearch: true)
        let tagged = command.toTaggedCommand(tag: "C006")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wireString.contains("UID SEARCH"))
        #expect(wireString.contains("RETURN"))
        #expect(!wireString.contains("UID 1"))
    }

    // MARK: - PARTIAL wire format

    @Test
    func testCommandWireFormatWithPartial() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let partialRange = NIOIMAPCore.PartialRange.first(NIOIMAPCore.SequenceRange(1...100))
        let command = ExtendedSearchCommand<UID>(
            criteria: [SearchCriteria.unseen],
            useEsearch: true,
            partialRange: partialRange
        )
        let tagged = command.toTaggedCommand(tag: "C007")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wireString.contains("UID SEARCH"))
        #expect(wireString.contains("RETURN"))
        #expect(wireString.contains("PARTIAL"))
        #expect(wireString.contains("1:100"))
        #expect(!wireString.contains("ALL"))
    }
}
