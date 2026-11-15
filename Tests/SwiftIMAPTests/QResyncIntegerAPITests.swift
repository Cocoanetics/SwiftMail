import Foundation
import NIO
import NIOIMAPCore
import Testing
@testable import SwiftMail

/// Plain-integer QRESYNC checkpoint API (RFC 7162): the integer select overloads must put the
/// same bytes on the wire as the typed overloads, reject out-of-range checkpoints before sending
/// anything, and the CONDSTORE/QRESYNC accessors must report exactly what was advertised.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct QResyncIntegerAPITests {
    // MARK: - Wire equivalence

    @Test(arguments: [
        (UInt32(777), UInt64(900)),
        (UInt32(1), UInt64(1)),
        (UInt32.max, UInt64(Int64.max))
    ])
    func primaryIntegerSelectSendsTheSameBytesAsTheTypedSelect(
        _ uidValidity: UInt32,
        _ modificationSequence: UInt64
    ) async throws {
        let typed = try await makeQResyncHarness(capabilities: [.qresync])
        let typedOperation = Task {
            try await typed.server.selectMailbox(
                "INBOX",
                resyncingFrom: UIDValidity(uidValidity),
                modificationSequence: ModificationSequenceValue(exactly: modificationSequence)!
            )
        }
        let typedLine = try await nextQResyncOutboundLine(from: typed.channel)
        try await writeQResyncInbound(typed.channel, "A001 OK [READ-WRITE] Selected\r\n")
        _ = try await typedOperation.value
        try await typed.channel.close()

        let integer = try await makeQResyncHarness(capabilities: [.qresync])
        let integerOperation = Task {
            try await integer.server.selectMailbox(
                "INBOX",
                resyncingFromUIDValidity: uidValidity,
                modificationSequence: modificationSequence
            )
        }
        let integerLine = try await nextQResyncOutboundLine(from: integer.channel)
        try await writeQResyncInbound(integer.channel, "A001 OK [READ-WRITE] Selected\r\n")
        _ = try await integerOperation.value

        #expect(typedLine != nil)
        #expect(integerLine == typedLine)
        #expect(integerLine == "A001 SELECT \"INBOX\" (QRESYNC (\(uidValidity) \(modificationSequence)))\r\n")
        try await integer.channel.close()
    }

    @Test
    func primaryIntegerSelectReturnsTheResyncResultAsIntegers() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.qresync])
        let operation = Task {
            try await harness.server.selectMailbox(
                "INBOX",
                resyncingFromUIDValidity: 777,
                modificationSequence: 900
            )
        }
        _ = try await nextQResyncOutboundLine(from: harness.channel)
        try await writeQResyncInbound(
            harness.channel,
            "* 3 EXISTS\r\n"
                + "* OK [UIDVALIDITY 777] Current\r\n"
                + "* OK [UIDNEXT 42] Next\r\n"
                + "* OK [HIGHESTMODSEQ 950] Highest\r\n"
                + "* VANISHED (EARLIER) 5:6\r\n"
                + "* 1 FETCH (UID 10 FLAGS (\\Seen) MODSEQ (940))\r\n"
                + "A001 OK [READ-WRITE] Selected\r\n"
        )

        let result = try await operation.value
        #expect(result.selection.uidValidity.value == 777)
        #expect(result.selection.uidNext.value == 42)
        #expect(result.selection.highestModificationSequenceValue == 950)
        #expect(result.vanishedEarlier.ranges == [5...6])
        #expect(result.changedFlags[UID(10)] == [.seen])
        try await harness.channel.close()
    }

    @Test
    func namedIntegerSelectAndAliasSendTheTypedBytes() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.qresync])
        let named = IMAPNamedConnection(
            name: "integer-sync",
            connection: harness.connection,
            authenticateOnConnection: { _ in }
        )

        let select = Task {
            try await named.select(mailbox: "INBOX", resyncingFromUIDValidity: 777, modificationSequence: 900)
        }
        #expect(
            try await nextQResyncOutboundLine(from: harness.channel)
                == "A001 SELECT \"INBOX\" (QRESYNC (777 900))\r\n"
        )
        try await writeQResyncInbound(harness.channel, "A001 OK [READ-WRITE] Selected\r\n")
        _ = try await select.value

        let alias = Task {
            try await named.selectMailbox("INBOX", resyncingFromUIDValidity: 777, modificationSequence: 901)
        }
        #expect(
            try await nextQResyncOutboundLine(from: harness.channel)
                == "A002 SELECT \"INBOX\" (QRESYNC (777 901))\r\n"
        )
        try await writeQResyncInbound(harness.channel, "A002 OK [READ-ONLY] Selected\r\n")
        #expect(try await alias.value.selection.isReadOnly)
        try await harness.channel.close()
    }

    // MARK: - Validation before the wire

    @Test(arguments: [
        (UInt32(0), UInt64(900)),
        (UInt32(777), UInt64(0)),
        (UInt32(777), UInt64(Int64.max) + 1),
        (UInt32(777), UInt64.max)
    ])
    func primaryIntegerSelectRejectsOutOfRangeCheckpointWithoutSending(
        _ uidValidity: UInt32,
        _ modificationSequence: UInt64
    ) async throws {
        let harness = try await makeQResyncHarness(capabilities: [.qresync])
        await expectInvalidArgument {
            _ = try await harness.server.selectMailbox(
                "INBOX",
                resyncingFromUIDValidity: uidValidity,
                modificationSequence: modificationSequence
            )
        }
        #expect(try await harness.channel.readOutbound(as: ByteBuffer.self) == nil)
        try await harness.channel.close()
    }

    @Test(arguments: [
        (UInt32(0), UInt64(900)),
        (UInt32(777), UInt64(0)),
        (UInt32(777), UInt64(Int64.max) + 1)
    ])
    func namedIntegerSelectRejectsOutOfRangeCheckpointWithoutSending(
        _ uidValidity: UInt32,
        _ modificationSequence: UInt64
    ) async throws {
        let harness = try await makeQResyncHarness(capabilities: [.qresync])
        let named = IMAPNamedConnection(
            name: "integer-validation",
            connection: harness.connection,
            authenticateOnConnection: { _ in }
        )
        await expectInvalidArgument {
            _ = try await named.select(
                mailbox: "INBOX",
                resyncingFromUIDValidity: uidValidity,
                modificationSequence: modificationSequence
            )
        }
        await expectInvalidArgument {
            _ = try await named.selectMailbox(
                "INBOX",
                resyncingFromUIDValidity: uidValidity,
                modificationSequence: modificationSequence
            )
        }
        #expect(try await harness.channel.readOutbound(as: ByteBuffer.self) == nil)
        try await harness.channel.close()
    }

    @Test
    func integerSelectWithoutQResyncThrowsAndSendsNothing() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.condStore])
        await #expect(throws: IMAPError.self) {
            _ = try await harness.server.selectMailbox(
                "INBOX",
                resyncingFromUIDValidity: 777,
                modificationSequence: 900
            )
        }
        let named = IMAPNamedConnection(
            name: "integer-unsupported",
            connection: harness.connection,
            authenticateOnConnection: { _ in }
        )
        await #expect(throws: IMAPError.self) {
            _ = try await named.select(mailbox: "INBOX", resyncingFromUIDValidity: 777, modificationSequence: 900)
        }
        #expect(try await harness.channel.readOutbound(as: ByteBuffer.self) == nil)
        try await harness.channel.close()
    }

    @Test(arguments: [UInt64(0), UInt64(Int64.max) + 1])
    func outOfRangeModificationSequenceIsRejectedBeforeTheCapabilityCheck(
        _ modificationSequence: UInt64
    ) async throws {
        // No QRESYNC advertised and not authenticated: only the argument check can answer.
        let harness = try await makeQResyncHarness(capabilities: [.condStore], authenticated: false)
        await expectInvalidArgument {
            _ = try await harness.server.selectMailbox(
                "INBOX",
                resyncingFromUIDValidity: 777,
                modificationSequence: modificationSequence
            )
        }
        let named = IMAPNamedConnection(
            name: "integer-early-validation",
            connection: harness.connection,
            authenticateOnConnection: { _ in Issue.record("Must not authenticate") }
        )
        await expectInvalidArgument {
            _ = try await named.select(
                mailbox: "INBOX",
                resyncingFromUIDValidity: 777,
                modificationSequence: modificationSequence
            )
        }
        await expectInvalidArgument {
            _ = try await named.selectMailbox(
                "INBOX",
                resyncingFromUIDValidity: 777,
                modificationSequence: modificationSequence
            )
        }
        #expect(try await harness.channel.readOutbound(as: ByteBuffer.self) == nil)
        try await harness.channel.close()
    }

    // MARK: - Selection accessor

    @Test
    func highestModificationSequenceValueMirrorsTheTypedValue() {
        var selection = Mailbox.Selection()
        #expect(selection.highestModificationSequenceValue == nil)

        selection.highestModSequence = 950
        #expect(selection.highestModificationSequenceValue == 950)

        selection.highestModSequence = ModificationSequenceValue(exactly: Int64.max)
        #expect(selection.highestModificationSequenceValue == UInt64(Int64.max))
    }

    // MARK: - Helpers

    private func expectInvalidArgument(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("Expected IMAPError.invalidArgument")
        } catch let error as IMAPError {
            guard case .invalidArgument = error else {
                Issue.record("Expected invalidArgument, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

/// CONDSTORE/QRESYNC accessors report exactly what the server advertised (RFC 7162).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CondStoreQResyncCapabilityTests {
    // MARK: - Capability accessors

    @Test(arguments: [
        (["CONDSTORE"], true, false),
        (["QRESYNC"], false, true),
        (["condstore", "QrEsYnC"], true, true),
        (["IMAP4rev1", "IDLE", "MOVE"], false, false),
        (["X-CONDSTORE", "QRESYNC-OTHER", "CONDSTORE=1", "QRESYNC=1"], false, false)
    ])
    func capabilityAccessorsReportExactlyWhatWasAdvertised(
        _ advertised: [String],
        _ expectCondStore: Bool,
        _ expectQResync: Bool
    ) async throws {
        let capabilities = Set(advertised.map { Capability($0) })
        let harness = try await makeQResyncHarness(capabilities: capabilities)
        #expect(await harness.server.supportsCondStore == expectCondStore)
        #expect(await harness.server.supportsQResync == expectQResync)

        let named = IMAPNamedConnection(
            name: "capabilities",
            connection: harness.connection,
            authenticateOnConnection: { _ in }
        )
        #expect(await named.supportsCondStore == expectCondStore)
        #expect(await named.supportsQResync == expectQResync)
        try await harness.channel.close()
    }

    @Test
    func capabilityAccessorsFollowARefreshedAdvertisement() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.imap4rev1])
        #expect(await harness.server.supportsQResync == false)
        #expect(await harness.server.supportsCondStore == false)

        harness.connection.replaceCapabilitiesForTesting([.imap4rev1, .condStore, .qresync])
        #expect(await harness.server.supportsQResync)
        #expect(await harness.server.supportsCondStore)
        try await harness.channel.close()
    }
}
