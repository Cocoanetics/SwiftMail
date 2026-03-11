import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

// Disambiguate SwiftMail types from NIOIMAPCore types with the same name.
private typealias UID = SwiftMail.UID
private typealias SequenceNumber = SwiftMail.SequenceNumber

struct SearchCommandTests {

    // MARK: - Wire format: identifierSet scope key

    @Test
    func testIdentifierSetScopeIncludedInUIDSearch() async throws {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        try await channel.pipeline.addHandler(IMAPClientHandler())

        let ids = MessageIdentifierSet<UID>([UID(10), UID(20), UID(30)])
        let command = SearchCommand<UID>(identifierSet: ids, criteria: [SearchCriteria.unseen])
        let tagged = command.toTaggedCommand(tag: "S001")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wire = outbound.readString(length: outbound.readableBytes) ?? ""

        // UID scope key must appear so the search is scoped to the provided set
        #expect(wire.contains("UID SEARCH"))
        #expect(wire.contains("UID 10:30") || wire.contains("UID 10,20,30"))
    }

    @Test
    func testNoIdentifierSetSearchesEntireMailbox() async throws {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        try await channel.pipeline.addHandler(IMAPClientHandler())

        let command = SearchCommand<UID>(identifierSet: nil, criteria: [SearchCriteria.unseen])
        let tagged = command.toTaggedCommand(tag: "S002")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wire = outbound.readString(length: outbound.readableBytes) ?? ""

        // No UID scope key when identifierSet is nil
        #expect(wire.contains("UID SEARCH"))
        #expect(!wire.contains("UID 10"))
    }

    @Test
    func testIdentifierSetScopeIncludedInSequenceNumberSearch() async throws {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        try await channel.pipeline.addHandler(IMAPClientHandler())

        let ids = MessageIdentifierSet<SequenceNumber>([SequenceNumber(1), SequenceNumber(2)])
        let command = SearchCommand<SequenceNumber>(identifierSet: ids, criteria: [SearchCriteria.unseen])
        let tagged = command.toTaggedCommand(tag: "S003")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wire = outbound.readString(length: outbound.readableBytes) ?? ""

        // Sequence number SEARCH (not UID SEARCH), with sequence set scope key
        #expect(!wire.contains("UID SEARCH"))
        #expect(wire.contains("SEARCH"))
        #expect(wire.contains("1:2") || wire.contains("1,2"))
    }

    @Test
    func testUIDExpungeUsesUIDCommandWireFormat() async throws {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        try await channel.pipeline.addHandler(IMAPClientHandler())

        let command = UIDExpungeCommand(identifierSet: UIDSet([UID(10), UID(20), UID(30)]))
        let tagged = command.toTaggedCommand(tag: "S004")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wire = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wire.contains("UID EXPUNGE"))
        #expect(wire.contains("10:30") || wire.contains("10,20,30"))
    }
}
