import SwiftMail

/// Compile-only coverage for source compatibility and inferred dependency types.
private func usePublicSelectionAPIs(
    server: IMAPServer,
    namedConnection: IMAPNamedConnection
) async throws {
    _ = try await server.enable([.qresync])
    let ordinarySelection: Mailbox.Selection = try await server.selectMailbox("INBOX")
    let _: Mailbox.ResyncSelection = try await server.selectMailbox(
        "INBOX",
        resyncingFrom: 777,
        modificationSequence: 900
    )

    let _: Mailbox.Selection = try await namedConnection.select(mailbox: "INBOX")
    let _: Mailbox.Selection = try await namedConnection.selectMailbox("INBOX")
    let _: Mailbox.ResyncSelection = try await namedConnection.select(
        mailbox: "INBOX",
        resyncingFrom: 777,
        modificationSequence: 900
    )
    let _: Mailbox.ResyncSelection = try await namedConnection.selectMailbox(
        "INBOX",
        resyncingFrom: 777,
        modificationSequence: 900
    )

    // Stored plain-integer checkpoints, not literals: no NIOIMAPCore type is named.
    let storedUIDValidity: UInt32 = ordinarySelection.uidValidity.value
    let storedModificationSequence: UInt64 = ordinarySelection.highestModificationSequenceValue ?? 1
    let _: UInt32 = ordinarySelection.uidNext.value
    let _: Bool = await server.supportsQResync
    let _: Bool = await server.supportsCondStore
    let _: Bool = await namedConnection.supportsQResync
    let _: Bool = await namedConnection.supportsCondStore
    let _: Mailbox.ResyncSelection = try await server.selectMailbox(
        "INBOX",
        resyncingFromUIDValidity: storedUIDValidity,
        modificationSequence: storedModificationSequence
    )
    let _: Mailbox.ResyncSelection = try await namedConnection.select(
        mailbox: "INBOX",
        resyncingFromUIDValidity: storedUIDValidity,
        modificationSequence: storedModificationSequence
    )
    let _: Mailbox.ResyncSelection = try await namedConnection.selectMailbox(
        "INBOX",
        resyncingFromUIDValidity: storedUIDValidity,
        modificationSequence: storedModificationSequence
    )

    _ = Mailbox.ResyncSelection(
        selection: ordinarySelection,
        vanishedEarlier: UIDSet(),
        changedFlags: [:]
    )
}
