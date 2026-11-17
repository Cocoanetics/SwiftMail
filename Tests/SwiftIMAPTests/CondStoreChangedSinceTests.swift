import Foundation
import NIO
import NIOIMAPCore
import Testing
@testable import SwiftMail

/// RFC 7162 CONDSTORE without QRESYNC: `UID FETCH … (CHANGEDSINCE n)` reports each changed
/// message's UID, complete flag set and MODSEQ.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CondStoreChangedSinceTests {
    // MARK: - Timeout

    @Test
    func changedSinceFetchWaitsAsLongAsAQResyncSelect() {
        let fetch = FetchChangedFlagsCommand(identifierSet: UIDSet(UID(1)...UID(99)), changedSince: 700)
        let select = ResyncSelectMailboxCommand(mailboxName: "INBOX", uidValidity: 777, modificationSequence: 700)
        #expect(fetch.timeoutSeconds == select.timeoutSeconds)
    }

    // MARK: - CHANGEDSINCE wire bytes

    @Test(arguments: [UInt64(1), UInt64(12_345), UInt64(Int64.max)])
    func changedSinceFetchSendsUIDFlagsModSeqWithTheModifier(_ modificationSequence: UInt64) async throws {
        let harness = try await makeQResyncHarness(capabilities: [.condStore])
        let operation = Task {
            try await harness.server.fetchFlagsChangedSince(
                UIDSet(UID(1)...UID(99)),
                modificationSequence: modificationSequence
            )
        }
        #expect(
            try await nextQResyncOutboundLine(from: harness.channel)
                == "A001 UID FETCH 1:99 (UID FLAGS MODSEQ) (CHANGEDSINCE \(modificationSequence))\r\n"
        )
        try await writeQResyncInbound(harness.channel, "A001 OK Fetch completed\r\n")
        _ = try await operation.value
        try await harness.channel.close()
    }

    @Test
    func namedConnectionSendsTheSameChangedSinceFetch() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.condStore])
        let named = IMAPNamedConnection(
            name: "changed-since",
            connection: harness.connection,
            authenticateOnConnection: { _ in }
        )
        let operation = Task {
            try await named.fetchFlagsChangedSince(UIDSet([UID(4), UID(9)]), modificationSequence: 700)
        }
        #expect(
            try await nextQResyncOutboundLine(from: harness.channel)
                == "A001 UID FETCH 4,9 (UID FLAGS MODSEQ) (CHANGEDSINCE 700)\r\n"
        )
        try await writeQResyncInbound(
            harness.channel,
            "* 2 FETCH (UID 9 FLAGS (\\Seen) MODSEQ (701))\r\n"
                + "A001 OK Fetch completed\r\n"
        )
        #expect(try await operation.value == [
            ChangedMessageFlags(uid: UID(9), flags: [.seen], modificationSequence: 701)
        ])
        try await harness.channel.close()
    }

    // MARK: - CHANGEDSINCE results

    @Test
    func changedMessagesAreKeyedByTheirUIDWithFlagsAndModSeq() async throws {
        // Out of UID order, attribute order varies, a keyword and a system flag mixed, an empty
        // flag list (every flag removed is a change too).
        let result = try await runChangedSince(
            "* 7 FETCH (UID 30 MODSEQ (905) FLAGS ($Forwarded \\Flagged))\r\n"
                + "* 2 FETCH (FLAGS (\\Seen) UID 12 MODSEQ (901))\r\n"
                + "* 4 FETCH (UID 20 FLAGS () MODSEQ (903))\r\n"
                + "A001 OK Fetch completed\r\n"
        )
        #expect(result == [
            ChangedMessageFlags(uid: UID(12), flags: [.seen], modificationSequence: 901),
            ChangedMessageFlags(uid: UID(20), flags: [], modificationSequence: 903),
            ChangedMessageFlags(uid: UID(30), flags: [.custom("$Forwarded"), .flagged], modificationSequence: 905)
        ])
    }

    @Test
    func noChangedMessageIsAnEmptyResult() async throws {
        let result = try await runChangedSince("A001 OK Fetch completed\r\n")
        #expect(result.isEmpty)
    }

    @Test
    func responsesOutsideTheRequestAreNotPartOfTheResult() async throws {
        // A sequence-number-only update carries no UID; UID 500 was not requested.
        let result = try await runChangedSince(
            "* 3 FETCH (FLAGS (\\Deleted) MODSEQ (950))\r\n"
                + "* 9 FETCH (UID 500 FLAGS (\\Seen) MODSEQ (951))\r\n"
                + "* 1 FETCH (UID 10 FLAGS (\\Answered) MODSEQ (952))\r\n"
                + "A001 OK Fetch completed\r\n"
        )
        #expect(result == [ChangedMessageFlags(uid: UID(10), flags: [.answered], modificationSequence: 952)])
    }

    @Test
    func laterResponsesForOneUIDReplaceEarlierValues() async throws {
        // An unsolicited update without MODSEQ, then the reply, then another update.
        let result = try await runChangedSince(
            "* 1 FETCH (UID 10 FLAGS (\\Seen))\r\n"
                + "* 1 FETCH (UID 10 FLAGS (\\Seen \\Flagged) MODSEQ (960))\r\n"
                + "* 1 FETCH (UID 10 FLAGS (\\Flagged) MODSEQ (961))\r\n"
                + "A001 OK Fetch completed\r\n"
        )
        #expect(result == [ChangedMessageFlags(uid: UID(10), flags: [.flagged], modificationSequence: 961)])
    }

    @Test
    func aLaterResponseWithOnlySomeItemsKeepsTheOthers() async throws {
        // A MODSEQ-only update after the complete reply changes the MODSEQ and keeps the flags.
        let result = try await runChangedSince(
            "* 1 FETCH (UID 10 FLAGS (\\Seen) MODSEQ (960))\r\n"
                + "* 1 FETCH (UID 10 MODSEQ (962))\r\n"
                + "A001 OK Fetch completed\r\n"
        )
        #expect(result == [ChangedMessageFlags(uid: UID(10), flags: [.seen], modificationSequence: 962)])
    }

    @Test
    func aFetchWithoutUIDAfterACompleteResponseDoesNotChangeIt() async throws {
        // An unsolicited sequence-number update (RFC 7162 section 3.2.4 makes the UID only a
        // SHOULD on CONDSTORE-only servers) must not be credited to the previous response's UID.
        let result = try await runChangedSince(
            "* 1 FETCH (UID 10 FLAGS (\\Answered) MODSEQ (952))\r\n"
                + "* 3 FETCH (FLAGS (\\Deleted) MODSEQ (953))\r\n"
                + "A001 OK Fetch completed\r\n"
        )
        #expect(result == [ChangedMessageFlags(uid: UID(10), flags: [.answered], modificationSequence: 952)])
    }

    @Test
    func anItemFromOneResponseDoesNotCompleteTheNextUID() async throws {
        // UID 11 is answered without MODSEQ; UID 10's MODSEQ must not fill it in.
        await #expect {
            _ = try await runChangedSince(
                "* 1 FETCH (UID 10 FLAGS (\\Seen) MODSEQ (952))\r\n"
                    + "* 2 FETCH (UID 11 FLAGS (\\Flagged))\r\n"
                    + "A001 OK Fetch completed\r\n"
            )
        } throws: { error in
            guard case IMAPError.fetchFailed = error else { return false }
            return true
        }
    }

    @Test
    func manyChangedMessagesComeBackInAscendingUIDOrder() async throws {
        // Eight UIDs out of order: an unsorted result passes by chance at most once in 40320 runs.
        let arrival: [UInt32] = [57, 3, 41, 12, 88, 26, 70, 9]
        let responses = arrival.enumerated().map { index, uid in
            "* \(index + 1) FETCH (UID \(uid) FLAGS (\\Seen) MODSEQ (\(1000 + uid)))\r\n"
        }.joined()
        let result = try await runChangedSince(responses + "A001 OK Fetch completed\r\n")
        #expect(result == arrival.sorted().map { uid in
            ChangedMessageFlags(uid: UID(uid), flags: [.seen], modificationSequence: UInt64(1000 + uid))
        })
    }

    @Test
    func uidOnlyFetchResponsesAreKeyedByTheirLeadingUID() async throws {
        // RFC 9586 UIDFETCH carries the UID in place of the sequence number.
        let result = try await runChangedSince(
            "* 10 UIDFETCH (FLAGS (\\Seen) MODSEQ (901))\r\n"
                + "A001 OK Fetch completed\r\n"
        )
        #expect(result == [ChangedMessageFlags(uid: UID(10), flags: [.seen], modificationSequence: 901)])
    }

    @Test(arguments: [
        "* 1 FETCH (UID 10 FLAGS (\\Seen))\r\n",
        "* 1 FETCH (UID 10 MODSEQ (970))\r\n"
    ])
    func aRequestedUIDWithoutFlagsOrModSeqFailsTheFetch(_ response: String) async throws {
        await #expect {
            _ = try await runChangedSince(response + "A001 OK Fetch completed\r\n")
        } throws: { error in
            guard case IMAPError.fetchFailed = error else { return false }
            return true
        }
    }

    @Test
    func aRejectedChangedSinceFetchThrows() async throws {
        // RFC 7162 section 3.1.2.2: a NOMODSEQ mailbox answers CHANGEDSINCE with a tagged BAD.
        await #expect {
            _ = try await runChangedSince("A001 BAD [NOMODSEQ] No modseq for this mailbox\r\n")
        } throws: { error in
            guard case IMAPError.fetchFailed = error else { return false }
            return true
        }
    }

    // MARK: - CHANGEDSINCE validation before the wire

    @Test(arguments: [UInt64(0), UInt64(Int64.max) + 1, UInt64.max])
    func anOutOfRangeModificationSequenceIsRejectedWithoutSending(_ modificationSequence: UInt64) async throws {
        // Not authenticated either: only the argument check can answer.
        let harness = try await makeQResyncHarness(capabilities: [.condStore], authenticated: false)
        await expectCondStoreError("invalidArgument") {
            _ = try await harness.server.fetchFlagsChangedSince(
                UIDSet(UID(1)...UID(9)),
                modificationSequence: modificationSequence
            )
        }
        let named = IMAPNamedConnection(
            name: "changed-since-validation",
            connection: harness.connection,
            authenticateOnConnection: { _ in Issue.record("Must not authenticate") }
        )
        await expectCondStoreError("invalidArgument") {
            _ = try await named.fetchFlagsChangedSince(
                UIDSet(UID(1)...UID(9)),
                modificationSequence: modificationSequence
            )
        }
        #expect(try await harness.channel.readOutbound(as: ByteBuffer.self) == nil)
        try await harness.channel.close()
    }

    @Test
    func anEmptyUIDSetIsRejectedWithoutSending() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.condStore])
        await expectCondStoreError("emptyIdentifierSet") {
            _ = try await harness.server.fetchFlagsChangedSince(UIDSet(), modificationSequence: 5)
        }
        #expect(try await harness.channel.readOutbound(as: ByteBuffer.self) == nil)
        try await harness.channel.close()
    }

    @Test
    func changedSinceWithoutCondStoreThrowsAndSendsNothing() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.imap4rev1, .enable])
        await expectCondStoreError("commandNotSupported") {
            _ = try await harness.server.fetchFlagsChangedSince(UIDSet(UID(1)...UID(9)), modificationSequence: 5)
        }
        let named = IMAPNamedConnection(
            name: "changed-since-unsupported",
            connection: harness.connection,
            authenticateOnConnection: { _ in }
        )
        await expectCondStoreError("commandNotSupported") {
            _ = try await named.fetchFlagsChangedSince(UIDSet(UID(1)...UID(9)), modificationSequence: 5)
        }
        #expect(try await harness.channel.readOutbound(as: ByteBuffer.self) == nil)
        try await harness.channel.close()
    }

    @Test
    func qresyncAloneAllowsChangedSince() async throws {
        // RFC 7162 section 3.2.3: a QRESYNC server implements CONDSTORE.
        let harness = try await makeQResyncHarness(capabilities: [.qresync])
        let operation = Task {
            try await harness.server.fetchFlagsChangedSince(UIDSet(UID(3)), modificationSequence: 8)
        }
        #expect(
            try await nextQResyncOutboundLine(from: harness.channel)
                == "A001 UID FETCH 3 (UID FLAGS MODSEQ) (CHANGEDSINCE 8)\r\n"
        )
        try await writeQResyncInbound(harness.channel, "A001 OK Fetch completed\r\n")
        #expect(try await operation.value.isEmpty)
        try await harness.channel.close()
    }

    // MARK: - Helpers

    /// Runs a CHANGEDSINCE fetch of UIDs 1:99 against `responses`.
    private func runChangedSince(_ responses: String) async throws -> [ChangedMessageFlags] {
        let harness = try await makeQResyncHarness(capabilities: [.condStore])
        let operation = Task {
            try await harness.server.fetchFlagsChangedSince(UIDSet(UID(1)...UID(99)), modificationSequence: 900)
        }
        _ = try await nextQResyncOutboundLine(from: harness.channel)
        try await writeQResyncInbound(harness.channel, responses)
        let result: Result<[ChangedMessageFlags], Error>
        do {
            result = .success(try await operation.value)
        } catch {
            result = .failure(error)
        }
        try await harness.channel.close()
        return try result.get()
    }
}

func expectCondStoreError(_ expected: String, _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("Expected IMAPError.\(expected)")
    } catch let error as IMAPError {
        let matches: Bool
        switch error {
            case .invalidArgument: matches = expected == "invalidArgument"
            case .emptyIdentifierSet: matches = expected == "emptyIdentifierSet"
            case .commandNotSupported: matches = expected == "commandNotSupported"
            default: matches = false
        }
        if !matches { Issue.record("Expected IMAPError.\(expected), got \(error)") }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
