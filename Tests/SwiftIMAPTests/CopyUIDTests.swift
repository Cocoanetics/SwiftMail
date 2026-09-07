import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

/// Tests COPYUID extraction and malformed-evidence handling for UID COPY and UID MOVE.
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
    func testCopyCardinalityMismatchOnTaggedOKThrowsTypedCompletionError() async {
        // Source has 2 UIDs, destination has 1 — malformed.
        await expectMalformedCopyUID {
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

    @Test
    func testMoveCardinalityMismatchOnTaggedOKThrowsTypedCompletionError() async {
        await expectMalformedCopyUID {
            try await executeMove(
                responses: ["A001 OK [COPYUID 1 1:2 200] MOVE completed\r\n"]
            )
        }
    }

    @Test
    func testMoveRetainsUntaggedOKCopyUIDAcrossExpungeResponses() async throws {
        let result = try await executeMove(
            responses: [
                "* OK [COPYUID 10 3 300] Moved\r\n",
                "* 1 EXPUNGE\r\n",
                "* 2 EXPUNGE\r\n",
                "A001 OK MOVE completed\r\n"
            ]
        )

        let copyUID = try #require(result)
        #expect(copyUID.destinationUIDValidity == UIDValidity(10))
        #expect(copyUID.mapping.map(\.source.value) == [3])
        #expect(copyUID.mapping.map(\.destination.value) == [300])
    }

    @Test
    func testMoveAcceptsMatchingUntaggedAndTaggedCopyUID() async throws {
        let result = try await executeMove(
            responses: [
                "* OK [COPYUID 10 3 300] Moved\r\n",
                "A001 OK [COPYUID 10 3 300] MOVE completed\r\n"
            ]
        )

        let copyUID = try #require(result)
        #expect(copyUID.mapping.map(\.destination.value) == [300])
    }

    @Test
    func testMoveRejectsConflictingUntaggedAndTaggedCopyUID() async {
        await expectMalformedCopyUID {
            try await executeMove(
                responses: [
                    "* OK [COPYUID 10 3 300] Moved\r\n",
                    "A001 OK [COPYUID 10 3 301] MOVE completed\r\n"
                ]
            )
        }
    }

    @Test
    func testMoveMalformedUntaggedCopyUIDThrowsOnlyAfterTaggedOK() async {
        await expectMalformedCopyUID {
            try await executeMove(
                responses: [
                    "* OK [COPYUID 1 1:2 200] Moved\r\n",
                    "* 1 EXPUNGE\r\n",
                    "A001 OK MOVE completed\r\n"
                ]
            )
        }
    }

    @Test
    func testMoveTaggedFailureWinsOverMalformedUntaggedCopyUID() async {
        do {
            _ = try await executeMove(
                responses: [
                    "* OK [COPYUID 1 1:2 200] Moved\r\n",
                    "A001 NO MOVE denied\r\n"
                ]
            )
            Issue.record("Expected tagged NO to report possible partial completion")
        } catch let error as IMAPError {
            guard case .moveFailedAfterPossiblePartialCompletion = error else {
                Issue.record("Expected possible partial completion, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected possible-partial IMAPError, got \(error)")
        }
    }

    @Test
    func testMoveTaggedNOReportsPossiblePartialCompletion() async {
        do {
            _ = try await executeMove(responses: ["A001 NO MOVE denied\r\n"])
            Issue.record("Expected possible partial completion")
        } catch let error as IMAPError {
            guard case .moveFailedAfterPossiblePartialCompletion = error else {
                Issue.record("Expected possible partial completion, got \(error)")
                return
            }
            #expect(error.recoverySuggestion?.contains("Do not retry") == true)
        } catch {
            Issue.record("Expected possible-partial IMAPError, got \(error)")
        }
    }

    @Test
    func testCopyTaggedNOThrowsCopyFailed() async {
        do {
            _ = try await executeCopy(responses: ["A001 NO COPY denied\r\n"])
            Issue.record("Expected tagged NO to throw copyFailed")
        } catch let error as IMAPError {
            guard case .copyFailed = error else {
                Issue.record("Expected copyFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected IMAPError.copyFailed, got \(error)")
        }
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

    private func expectMalformedCopyUID(
        _ operation: () async throws -> CopyUID?
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected malformedCopyUIDAfterTaggedOK")
        } catch let error as IMAPError {
            guard case .malformedCopyUIDAfterTaggedOK = error else {
                Issue.record("Expected malformedCopyUIDAfterTaggedOK, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected IMAPError.malformedCopyUIDAfterTaggedOK, got \(error)")
        }
    }
}

extension CopyUIDTests {
    @Test(
        "COPY and MOVE reject wildcard COPYUID members",
        arguments: [
            "A001 OK [COPYUID 42 * 101] completed\r\n",
            "A001 OK [COPYUID 42 1 *] completed\r\n",
            "A001 OK [COPYUID 42 1:* 101:102] completed\r\n"
        ]
    )
    func testWildcardCopyUIDMembersAreRejected(_ response: String) async {
        await expectMalformedCopyUID {
            try await executeCopy(responses: [response])
        }
        await expectMalformedCopyUID {
            try await executeMove(responses: [response])
        }
    }

    @Test
    func testNormalizedNumericMaximumIsConservativelyRejected() async {
        let response = "A001 OK [COPYUID 42 4294967295 101] completed\r\n"
        await expectMalformedCopyUID {
            try await executeCopy(responses: [response])
        }
        await expectMalformedCopyUID {
            try await executeMove(responses: [response])
        }
    }

    @Test(
        "COPY and MOVE reject repeated COPYUID members",
        arguments: [
            "A001 OK [COPYUID 42 1,1 101,102] completed\r\n",
            "A001 OK [COPYUID 42 1:2,2 101:103] completed\r\n",
            "A001 OK [COPYUID 42 1,2 101,101] completed\r\n",
            "A001 OK [COPYUID 42 1:3 101:102,102] completed\r\n"
        ]
    )
    func testRepeatedCopyUIDMembersAreRejected(_ response: String) async {
        await expectMalformedCopyUID {
            try await executeCopy(responses: [response])
        }
        await expectMalformedCopyUID {
            try await executeMove(responses: [response])
        }
    }

    @Test
    func testMoveTaggedFailurePreservesVerifiedPartialMapping() async {
        do {
            _ = try await executeMove(
                responses: [
                    "* OK [COPYUID 10 3:4 300:301] Partially moved\r\n",
                    "A001 NO MOVE failed after partial completion\r\n"
                ]
            )
            Issue.record("Expected moveFailedAfterPartialCompletion")
        } catch let error as IMAPError {
            guard case .moveFailedAfterPartialCompletion(let copyUID, let reason) = error else {
                Issue.record("Expected moveFailedAfterPartialCompletion, got \(error)")
                return
            }
            #expect(copyUID.destinationUIDValidity == UIDValidity(10))
            #expect(copyUID.mapping.map(\.source.value) == [3, 4])
            #expect(copyUID.mapping.map(\.destination.value) == [300, 301])
            #expect(reason.contains("MOVE failed after partial completion"))
            #expect(error.recoverySuggestion?.contains("Do not retry blindly") == true)
        } catch {
            Issue.record("Expected IMAPError.moveFailedAfterPartialCompletion, got \(error)")
        }
    }

    @Test
    func testMalformedCopyUIDRecoveryDoesNotSuggestRetry() {
        let error = IMAPError.malformedCopyUIDAfterTaggedOK("duplicate source UID")
        #expect(error.recoverySuggestion?.contains("Do not retry") == true)
    }

    @Test
    func testLegacyMoveFailureRecoveryDoesNotSuggestRetry() {
        let error = IMAPError.moveFailed("server rejected MOVE")
        #expect(error.recoverySuggestion?.contains("Do not retry") == true)
    }
}
