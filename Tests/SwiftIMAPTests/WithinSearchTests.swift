import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite(.timeLimit(.minutes(1)))
struct WithinSearchTests {
    @Test
    func testYoungerSearchKeyWireFormat() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let command = SearchCommand<SwiftMail.UID>(criteria: [SearchCriteria.younger(seconds: 3600)])
        let tagged = command.toTaggedCommand(tag: "W001")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wireString.contains("UID SEARCH"))
        #expect(wireString.contains("YOUNGER 3600"))
    }

    @Test
    func testOlderSearchKeyWireFormat() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let command = SearchCommand<SwiftMail.UID>(criteria: [SearchCriteria.older(seconds: 86400)])
        let tagged = command.toTaggedCommand(tag: "W002")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wireString.contains("UID SEARCH"))
        #expect(wireString.contains("OLDER 86400"))
    }

    @Test
    func testWithinCriteriaWithExtendedSearch() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let command = ExtendedSearchCommand<SwiftMail.UID>(criteria: [SearchCriteria.younger(seconds: 600)], useEsearch: true)
        let tagged = command.toTaggedCommand(tag: "W003")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wireString.contains("UID SEARCH"))
        #expect(wireString.contains("YOUNGER 600"))
        #expect(wireString.contains("RETURN"))
    }

    @Test
    func testCombinedWithinAndOtherCriteria() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let command = SearchCommand<SwiftMail.UID>(criteria: [SearchCriteria.younger(seconds: 3600), SearchCriteria.unseen])
        let tagged = command.toTaggedCommand(tag: "W004")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wireString.contains("UID SEARCH"))
        #expect(wireString.contains("YOUNGER 3600"))
        #expect(wireString.contains("UNSEEN"))
    }

    @Test
    func testZeroIntervalThrows() async throws {
        #expect(throws: (any Error).self) {
            try SearchCriteria.younger(seconds: 0).validate()
        }
        #expect(throws: (any Error).self) {
            try SearchCriteria.older(seconds: 0).validate()
        }
    }

    @Test
    func testNegativeIntervalThrows() async throws {
        #expect(throws: (any Error).self) {
            try SearchCriteria.younger(seconds: -100).validate()
        }
        #expect(throws: (any Error).self) {
            try SearchCriteria.older(seconds: -1).validate()
        }
    }
}
