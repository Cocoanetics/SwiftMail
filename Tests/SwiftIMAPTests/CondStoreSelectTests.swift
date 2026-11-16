import Foundation
import NIO
import NIOIMAPCore
import Testing
@testable import SwiftMail

/// `SELECT … (CONDSTORE)` (RFC 7162 section 3.1.8) reports HIGHESTMODSEQ or NOMODSEQ.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CondStoreSelectTests {
    @Test
    func condStoreSelectSendsTheParameterAndReadsHighestModSeq() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.condStore])
        let operation = Task {
            try await harness.server.selectMailbox("INBOX", enablingCondStore: true)
        }
        #expect(
            try await nextQResyncOutboundLine(from: harness.channel)
                == "A001 SELECT \"INBOX\" (CONDSTORE)\r\n"
        )
        try await writeQResyncInbound(
            harness.channel,
            "* 172 EXISTS\r\n"
                + "* OK [UIDVALIDITY 3857529045] Ok\r\n"
                + "* OK [UIDNEXT 4392] Predicted next UID\r\n"
                + "* OK [HIGHESTMODSEQ 715194045007] Highest\r\n"
                + "A001 OK [READ-WRITE] SELECT completed, CONDSTORE is now enabled\r\n"
        )
        let selection = try await operation.value
        #expect(selection.messageCount == 172)
        #expect(selection.uidValidity.value == 3_857_529_045)
        #expect(selection.uidNext.value == 4392)
        #expect(selection.highestModificationSequenceValue == 715_194_045_007)
        try await harness.channel.close()
    }

    @Test
    func condStoreSelectOfANoModSeqMailboxHasNoHighestModSeq() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.condStore])
        let operation = Task {
            try await harness.server.selectMailbox("Shared", enablingCondStore: true)
        }
        #expect(
            try await nextQResyncOutboundLine(from: harness.channel)
                == "A001 SELECT \"Shared\" (CONDSTORE)\r\n"
        )
        try await writeQResyncInbound(
            harness.channel,
            "* 5 EXISTS\r\n"
                + "* OK [UIDVALIDITY 42] Ok\r\n"
                + "* OK [NOMODSEQ] Sorry, this mailbox format doesn't support modsequences\r\n"
                + "A001 OK [READ-WRITE] SELECT completed\r\n"
        )
        let selection = try await operation.value
        #expect(selection.messageCount == 5)
        #expect(selection.highestModSequence == nil)
        #expect(selection.highestModificationSequenceValue == nil)
        try await harness.channel.close()
    }

    @Test
    func selectWithoutEnablingCondStoreIsThePlainSelect() async throws {
        // No CONDSTORE advertised: the plain select needs no capability.
        let harness = try await makeQResyncHarness(capabilities: [.imap4rev1])
        let operation = Task {
            try await harness.server.selectMailbox("INBOX", enablingCondStore: false)
        }
        #expect(try await nextQResyncOutboundLine(from: harness.channel) == "A001 SELECT \"INBOX\"\r\n")
        try await writeQResyncInbound(harness.channel, "A001 OK [READ-WRITE] Selected\r\n")
        _ = try await operation.value
        try await harness.channel.close()
    }

    @Test
    func namedSelectWithoutEnablingCondStoreIsThePlainSelect() async throws {
        // No CONDSTORE advertised: neither the select nor its alias checks the capability.
        let harness = try await makeQResyncHarness(capabilities: [.imap4rev1])
        let named = IMAPNamedConnection(
            name: "plain-select",
            connection: harness.connection,
            authenticateOnConnection: { _ in }
        )

        let select = Task { try await named.select(mailbox: "INBOX", enablingCondStore: false) }
        #expect(try await nextQResyncOutboundLine(from: harness.channel) == "A001 SELECT \"INBOX\"\r\n")
        try await writeQResyncInbound(harness.channel, "A001 OK [READ-WRITE] Selected\r\n")
        _ = try await select.value

        let alias = Task { try await named.selectMailbox("INBOX", enablingCondStore: false) }
        #expect(try await nextQResyncOutboundLine(from: harness.channel) == "A002 SELECT \"INBOX\"\r\n")
        try await writeQResyncInbound(harness.channel, "A002 OK [READ-WRITE] Selected\r\n")
        _ = try await alias.value
        try await harness.channel.close()
    }

    @Test
    func namedCondStoreSelectAndAliasSendTheParameter() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.condStore])
        let named = IMAPNamedConnection(
            name: "condstore-select",
            connection: harness.connection,
            authenticateOnConnection: { _ in }
        )

        let select = Task { try await named.select(mailbox: "INBOX", enablingCondStore: true) }
        #expect(
            try await nextQResyncOutboundLine(from: harness.channel)
                == "A001 SELECT \"INBOX\" (CONDSTORE)\r\n"
        )
        try await writeQResyncInbound(
            harness.channel,
            "* OK [HIGHESTMODSEQ 90] Highest\r\nA001 OK [READ-WRITE] Selected\r\n"
        )
        #expect(try await select.value.highestModificationSequenceValue == 90)

        let alias = Task { try await named.selectMailbox("INBOX", enablingCondStore: true) }
        #expect(
            try await nextQResyncOutboundLine(from: harness.channel)
                == "A002 SELECT \"INBOX\" (CONDSTORE)\r\n"
        )
        try await writeQResyncInbound(
            harness.channel,
            "* OK [NOMODSEQ] No modseq\r\nA002 OK [READ-ONLY] Selected\r\n"
        )
        let aliasSelection = try await alias.value
        #expect(aliasSelection.isReadOnly)
        #expect(aliasSelection.highestModificationSequenceValue == nil)
        try await harness.channel.close()
    }

    @Test
    func condStoreSelectWithoutCondStoreThrowsAndSendsNothing() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.imap4rev1, .enable])
        await expectCondStoreError("commandNotSupported") {
            _ = try await harness.server.selectMailbox("INBOX", enablingCondStore: true)
        }
        let named = IMAPNamedConnection(
            name: "condstore-select-unsupported",
            connection: harness.connection,
            authenticateOnConnection: { _ in }
        )
        await expectCondStoreError("commandNotSupported") {
            _ = try await named.select(mailbox: "INBOX", enablingCondStore: true)
        }
        #expect(try await harness.channel.readOutbound(as: ByteBuffer.self) == nil)
        try await harness.channel.close()
    }
}
