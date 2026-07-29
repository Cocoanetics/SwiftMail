import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

/// Tests for COPYUID extraction from UID COPY and UID MOVE tagged responses.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CopyUIDTests {

    // MARK: - CopyHandler — single UID

    @Test
    func testSingleUIDCopyReturnsMapping() async throws {
        let result = try await executeCopy(
            responses: ["A001 OK [COPYUID 42 5 101] COPY completed\r\n"]
        )
        let copyUID = try #require(result)
        #expect(copyUID.destinationUIDValidity == UIDValidity(42))
        #expect(copyUID.mapping.count == 1)
        #expect(copyUID.mapping[0].source.value == 5)
        #expect(copyUID.mapping[0].destination.value == 101)
    }

    // MARK: - CopyHandler — contiguous range

    @Test
    func testRangeCopyPreservesOrder() async throws {
        let result = try await executeCopy(
            responses: ["A001 OK [COPYUID 99 1:3 201:203] COPY completed\r\n"]
        )
        let copyUID = try #require(result)
        #expect(copyUID.destinationUIDValidity == UIDValidity(99))
        let pairs = copyUID.mapping
        #expect(pairs.count == 3)
        #expect(pairs[0].source.value == 1 && pairs[0].destination.value == 201)
        #expect(pairs[1].source.value == 2 && pairs[1].destination.value == 202)
        #expect(pairs[2].source.value == 3 && pairs[2].destination.value == 203)
    }

    // MARK: - CopyHandler — non-contiguous UID set

    @Test
    func testNonContiguousSetPreservesCorrespondence() async throws {
        // Source: 1,3,7 → Destination: 101,103,107
        let result = try await executeCopy(
            responses: ["A001 OK [COPYUID 7 1,3,7 101,103,107] COPY completed\r\n"]
        )
        let copyUID = try #require(result)
        let pairs = copyUID.mapping
        #expect(pairs.count == 3)
        #expect(pairs[0].source.value == 1 && pairs[0].destination.value == 101)
        #expect(pairs[1].source.value == 3 && pairs[1].destination.value == 103)
        #expect(pairs[2].source.value == 7 && pairs[2].destination.value == 107)
    }

    // MARK: - CopyHandler — mixed ranges and singles

    @Test
    func testMixedRangeAndSinglesInCopyUID() async throws {
        // Source: 1:2,5 → Destination: 10:11,20
        let result = try await executeCopy(
            responses: ["A001 OK [COPYUID 55 1:2,5 10:11,20] COPY completed\r\n"]
        )
        let copyUID = try #require(result)
        let pairs = copyUID.mapping
        #expect(pairs.count == 3)
        #expect(pairs[0].source.value == 1 && pairs[0].destination.value == 10)
        #expect(pairs[1].source.value == 2 && pairs[1].destination.value == 11)
        #expect(pairs[2].source.value == 5 && pairs[2].destination.value == 20)
    }

    // MARK: - CopyHandler — COPYUID absent

    @Test
    func testMissingCopyUIDReturnsNil() async throws {
        let result = try await executeCopy(
            responses: ["A001 OK COPY completed\r\n"]
        )
        #expect(result == nil)
    }

    // MARK: - CopyHandler — cardinality mismatch

    @Test
    func testCardinalityMismatchThrows() async throws {
        // Source has 2 UIDs, destination has 1 — malformed.
        await #expect(throws: (any Error).self) {
            try await executeCopy(
                responses: ["A001 OK [COPYUID 1 1:2 200] COPY completed\r\n"]
            )
        }
    }

    // MARK: - MoveHandler — COPYUID present

    @Test
    func testMoveReturnsCopyUID() async throws {
        let result = try await executeMove(
            responses: ["A001 OK [COPYUID 10 3 300] MOVE completed\r\n"]
        )
        let copyUID = try #require(result)
        #expect(copyUID.destinationUIDValidity == UIDValidity(10))
        #expect(copyUID.mapping.count == 1)
        #expect(copyUID.mapping[0].source.value == 3)
        #expect(copyUID.mapping[0].destination.value == 300)
    }

    // MARK: - MoveHandler — COPYUID absent

    @Test
    func testMoveWithoutCopyUIDReturnsNil() async throws {
        let result = try await executeMove(
            responses: ["A001 OK MOVE completed\r\n"]
        )
        #expect(result == nil)
    }

    // MARK: - CopyUID model — maximum uidValidity

    @Test
    func testMaxUIDValidityIsPassedThrough() async throws {
        let result = try await executeCopy(
            responses: ["A001 OK [COPYUID 4294967295 1 2] COPY completed\r\n"]
        )
        let copyUID = try #require(result)
        #expect(copyUID.destinationUIDValidity.value == 4_294_967_295)
    }

    // MARK: - Helpers

    /// Drives a `CopyHandler` against the given raw server response lines and returns the result.
    private func executeCopy(responses: [String]) async throws -> CopyUID? {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()

        let promise = channel.eventLoop.makePromise(of: CopyUID?.self)
        let handler = CopyHandler(commandTag: "A001", promise: promise)
        try await channel.pipeline.addHandler(handler)

        // Flush a placeholder tagged command so the pipeline accepts the inbound response.
        let noop = TaggedCommand(tag: "A001", command: .noop)
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(noop)))
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        for response in responses {
            var buffer = channel.allocator.buffer(capacity: response.utf8.count)
            buffer.writeString(response)
            try await channel.writeInbound(buffer)
        }

        return try await promise.futureResult.get()
    }

    /// Drives a `MoveHandler` against the given raw server response lines and returns the result.
    private func executeMove(responses: [String]) async throws -> CopyUID? {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()

        let promise = channel.eventLoop.makePromise(of: CopyUID?.self)
        let handler = MoveHandler(commandTag: "A001", promise: promise)
        try await channel.pipeline.addHandler(handler)

        let noop = TaggedCommand(tag: "A001", command: .noop)
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(noop)))
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        for response in responses {
            var buffer = channel.allocator.buffer(capacity: response.utf8.count)
            buffer.writeString(response)
            try await channel.writeInbound(buffer)
        }

        return try await promise.futureResult.get()
    }
}
