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

    _ = Mailbox.ResyncSelection(
        selection: ordinarySelection,
        vanishedEarlier: UIDSet(),
        changedFlags: [:]
    )
}
