import Foundation
import NIO
import NIOIMAPCore
import Testing
@testable import SwiftMail

/// `UID FETCH … (CHANGEDSINCE n)` with a UID set holding `UID.latest`, which goes on the wire as `*`.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CondStoreChangedSinceWildcardTests {
    /// The mailbox's highest UID is 42 and it changed. `UID.latest` goes on the wire as `*`, so
    /// `*` and `100:*` both resolve to UID 42 alone (RFC 3501 section 6.4.8: a range with `*`
    /// always includes the highest UID, even when the other endpoint is above it).
    @Test(arguments: [UInt32.max, 100])
    func aWildcardRequestNeverReportsTheHighestUIDAsUnchanged(_ wildcardLowerBound: UInt32) async throws {
        let harness = try await makeQResyncHarness(capabilities: [.condStore])
        let uids = UIDSet(UID(wildcardLowerBound)...)
        let exchange = try await answerIfSent(
            on: harness.channel,
            with: "* 7 FETCH (UID 42 FLAGS (\\Seen) MODSEQ (901))\r\n" + "A001 OK Fetch completed\r\n"
        ) {
            try await harness.server.fetchFlagsChangedSince(uids, modificationSequence: 900)
        }
        // Refusing the set is honest; sending it and then reporting no change is not.
        if case .success(let changes) = exchange.outcome {
            #expect(
                changes == [ChangedMessageFlags(uid: UID(42), flags: [.seen], modificationSequence: 901)],
                "Sent \(exchange.sentLine ?? "nothing")"
            )
        }
        try await harness.channel.close()
    }

    /// A set holding `*` whose range does not start at 1 has no fixed meaning: when its lower
    /// endpoint is above the highest UID it means that UID alone, and the reply for it looks
    /// exactly like an unsolicited update from another session (RFC 7162 section 3.1.4.2).
    @Test(arguments: [
        SwiftMail.UIDSet(UID.latest),
        SwiftMail.UIDSet(UID(100)...),
        SwiftMail.UIDSet(UID(2)...),
        SwiftMail.UIDSet([UID(5), UID.latest]),
        SwiftMail.UIDSet(ranges: 1...5, 100...Int(UInt32.max))
    ])
    func aWildcardSetThatDoesNotStartAtOneIsRejectedWithoutSending(_ uids: SwiftMail.UIDSet) async throws {
        for onNamedConnection in [false, true] {
            let harness = try await makeQResyncHarness(capabilities: [.condStore])
            let named = IMAPNamedConnection(
                name: "changed-since-wildcard",
                connection: harness.connection,
                authenticateOnConnection: { _ in }
            )
            let exchange = try await answerIfSent(on: harness.channel, with: "A001 OK Fetch completed\r\n") {
                onNamedConnection
                    ? try await named.fetchFlagsChangedSince(uids, modificationSequence: 900)
                    : try await harness.server.fetchFlagsChangedSince(uids, modificationSequence: 900)
            }
            #expect(exchange.sentLine == nil, "Named connection: \(onNamedConnection)")
            await expectCondStoreError("invalidArgument") { _ = try exchange.outcome.get() }
            try await harness.channel.close()
        }
    }

    /// `1:*` means every UID to the server whatever the highest UID is, so every reply belongs to it.
    @Test
    func theWholeMailboxWildcardIsSentAndEveryReplyBelongsToIt() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.condStore])
        let operation = Task {
            try await harness.server.fetchFlagsChangedSince(UIDSet(UID(1)...), modificationSequence: 900)
        }
        #expect(
            try await nextQResyncOutboundLine(from: harness.channel)
                == "A001 UID FETCH 1:* (UID FLAGS MODSEQ) (CHANGEDSINCE 900)\r\n"
        )
        try await writeQResyncInbound(
            harness.channel,
            "* 1 FETCH (UID 1 FLAGS (\\Seen) MODSEQ (901))\r\n"
                + "* 2 FETCH (UID 4000000000 FLAGS () MODSEQ (902))\r\n"
                + "A001 OK Fetch completed\r\n"
        )
        #expect(try await operation.value == [
            ChangedMessageFlags(uid: UID(1), flags: [.seen], modificationSequence: 901),
            ChangedMessageFlags(uid: UID(4_000_000_000), flags: [], modificationSequence: 902)
        ])
        try await harness.channel.close()
    }

    // MARK: - Helpers

    /// Runs `call`. If it sends a command before it finishes, answers with `responses`. Returns
    /// the line it sent (nil when it finished without sending) and how it finished.
    private func answerIfSent(
        on channel: NIOAsyncTestingChannel,
        with responses: String,
        _ call: @escaping @Sendable () async throws -> [ChangedMessageFlags]
    ) async throws -> (sentLine: String?, outcome: Result<[ChangedMessageFlags], any Error>) {
        let operation = Task { try await call() }
        let sentLine = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                _ = await operation.result
                return nil
            }
            group.addTask {
                while true {
                    if var line = try await channel.readOutbound(as: ByteBuffer.self) {
                        try await writeQResyncInbound(channel, responses)
                        return line.readString(length: line.readableBytes)
                    }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return (sentLine, await operation.result)
    }
}
