import Foundation
import NIO
import NIOEmbedded
import NIOIMAPCore
import Testing
@testable import SwiftMail

enum OrdinarySelectionRoute: CaseIterable, Sendable {
    case primary
    case named
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct OrdinarySelectionAfterQResyncTests {
    @Test(arguments: OrdinarySelectionRoute.allCases)
    func liveVanishedIsAppliedWhileResponseBufferIsActive(
        _ route: OrdinarySelectionRoute
    ) async throws {
        let harness = try await makeQResyncHarness(capabilities: [.enable, .qresync])
        let named = IMAPNamedConnection(
            name: "ordinary-sync",
            connection: harness.connection,
            authenticateOnConnection: { _ in }
        )
        let enableOperation: Task<[Capability], Error>
        switch route {
            case .primary:
                enableOperation = Task { try await harness.server.enable([.qresync]) }
            case .named:
                enableOperation = Task { try await named.enable([.qresync]) }
        }

        #expect(try await nextQResyncOutboundLine(from: harness.channel) == "A001 ENABLE QRESYNC\r\n")
        try await writeQResyncInbound(harness.channel, "* ENABLED QRESYNC\r\nA001 OK Enabled\r\n")
        #expect(try await enableOperation.value == [.qresync])

        let selectionOperation: Task<Mailbox.Selection, Error>
        let expectedCommand: String
        switch route {
            case .primary:
                selectionOperation = Task { try await harness.server.selectMailbox("INBOX") }
                expectedCommand = "A002 SELECT \"INBOX\"\r\n"
            case .named:
                selectionOperation = Task { try await named.select(mailbox: "Archive") }
                expectedCommand = "A002 SELECT \"Archive\"\r\n"
        }

        #expect(try await nextQResyncOutboundLine(from: harness.channel) == expectedCommand)
        #expect(harness.connection.responseBuffer.hasActiveHandler)
        try await writeQResyncInbound(
            harness.channel,
            "* 5 EXISTS\r\n* VANISHED 42\r\nA002 OK [READ-WRITE] Selected\r\n"
        )

        #expect(try await selectionOperation.value.messageCount == 4)
        #expect(harness.connection.responseBuffer.bufferedCount == 0)
        try await harness.channel.close()
    }

    @Test
    func ordinarySelectionAfterMissingQResyncCheckpointAppliesLiveVanished() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.enable, .qresync])
        let enableOperation = Task { try await harness.server.enable([.qresync]) }
        #expect(try await nextQResyncOutboundLine(from: harness.channel) == "A001 ENABLE QRESYNC\r\n")
        try await writeQResyncInbound(harness.channel, "* ENABLED QRESYNC\r\nA001 OK Enabled\r\n")
        _ = try await enableOperation.value

        let resyncOperation = Task {
            try await harness.server.selectMailbox(
                "INBOX",
                resyncingFrom: 777,
                modificationSequence: 900
            )
        }
        #expect(
            try await nextQResyncOutboundLine(from: harness.channel)
                == "A002 SELECT \"INBOX\" (QRESYNC (777 900))\r\n"
        )
        try await writeQResyncInbound(
            harness.channel,
            "* 5 EXISTS\r\n* OK [UIDVALIDITY 777] Current\r\nA002 OK [READ-WRITE] Selected\r\n"
        )
        #expect(try await resyncOperation.value.selection.highestModSequence == nil)

        let ordinaryOperation = Task { try await harness.server.selectMailbox("INBOX") }
        #expect(
            try await nextQResyncOutboundLine(from: harness.channel)
                == "A003 SELECT \"INBOX\"\r\n"
        )
        try await writeQResyncInbound(
            harness.channel,
            "* 5 EXISTS\r\n* VANISHED 42\r\nA003 OK [READ-WRITE] Selected\r\n"
        )

        #expect(try await ordinaryOperation.value.messageCount == 4)
        #expect(harness.connection.responseBuffer.bufferedCount == 0)
        try await harness.channel.close()
    }
}
