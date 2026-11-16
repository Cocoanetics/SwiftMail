import Foundation
import NIOIMAPCore

// MARK: - CONDSTORE (RFC 7162 section 3.1)

extension IMAPServer {
    /// Selects a mailbox, optionally with the RFC 7162 `CONDSTORE` select parameter.
    ///
    /// `SELECT <mailbox> (CONDSTORE)` makes this connection CONDSTORE-aware without `ENABLE`,
    /// for servers that advertise CONDSTORE but not ENABLE. The server then reports the
    /// mailbox's HIGHESTMODSEQ in the selection, or NOMODSEQ (``Mailbox/Selection/highestModificationSequenceValue``
    /// is nil) when the mailbox keeps no modification sequences. With `enablingCondStore` false this
    /// is ``selectMailbox(_:)``.
    ///
    /// A server that advertises QRESYNC implements CONDSTORE (RFC 7162 section 3.2.3), so either
    /// capability allows the parameter.
    ///
    /// - Throws: ``IMAPError/commandNotSupported(_:)`` when `enablingCondStore` is true and neither
    ///   CONDSTORE nor QRESYNC was advertised (nothing is sent), or ``IMAPError/selectFailed(_:)``
    ///   when the server rejects the selection.
    @discardableResult
    public func selectMailbox(_ mailboxName: String, enablingCondStore: Bool) async throws -> Mailbox.Selection {
        try await withAuthenticatedPrimaryOperation { [self] in
            if enablingCondStore {
                try primaryConnection.capabilitiesSnapshot.requireCondStore()
            }
            let command = SelectMailboxCommand(
                mailboxName: resolveMailboxPath(mailboxName),
                condStore: enablingCondStore
            )
            return try await primaryConnection.executeCommand(command)
        }
    }

    /// Fetches the flags of the messages in `uids` whose modification sequence is greater than
    /// `modificationSequence`.
    ///
    /// Sends `UID FETCH <uids> (UID FLAGS MODSEQ) (CHANGEDSINCE <modificationSequence>)`
    /// (RFC 7162 section 3.1.4.1) on the selected mailbox. Each result holds the message's
    /// complete current flag set and its MODSEQ, in ascending UID order. An empty result means
    /// no message in `uids` changed. Messages expunged since then are not reported; CHANGEDSINCE
    /// only reports messages that still exist.
    ///
    /// The command is itself a CONDSTORE enabling command, so the connection needs no `ENABLE`
    /// first. Select the mailbox before calling this; a mailbox selected with NOMODSEQ answers
    /// with a tagged BAD, which throws.
    ///
    /// Take the next checkpoint from the HIGHESTMODSEQ of the SELECT before this call, not from
    /// the largest MODSEQ in the result.
    ///
    /// - Parameters:
    ///   - uids: The messages to check. Must not be empty. ``UID/latest`` is sent as `*`, so a
    ///     set holding it must be every UID, `UIDSet(UID(1)...)` (sent as `1:*`): `n:*` with `n`
    ///     above the mailbox's highest UID means that UID alone (RFC 3501 section 6.4.8), and its
    ///     reply cannot be told apart from an unsolicited update.
    ///   - modificationSequence: The modification sequence the caller already knows about,
    ///     typically a stored HIGHESTMODSEQ. Must be in `1...Int64.max`.
    /// - Returns: The changed messages, in ascending UID order.
    /// - Throws: ``IMAPError/invalidArgument(_:)`` for a modification sequence outside
    ///   `1...Int64.max` (before any network activity) or for `uids` holding ``UID/latest`` without
    ///   being `1:*` (nothing is sent), ``IMAPError/emptyIdentifierSet`` for empty
    ///   `uids`, ``IMAPError/commandNotSupported(_:)`` when neither CONDSTORE nor QRESYNC was
    ///   advertised (nothing is sent), or ``IMAPError/fetchFailed(_:)`` when the server rejects the
    ///   command or answers a requested UID without both FLAGS and MODSEQ.
    public func fetchFlagsChangedSince(
        _ uids: UIDSet,
        modificationSequence: UInt64
    ) async throws -> [ChangedMessageFlags] {
        let changedSince = try ResyncSelectMailboxCommand.modificationSequence(fromRawValue: modificationSequence)
        return try await withAuthenticatedPrimaryOperation { [self] in
            try primaryConnection.capabilitiesSnapshot.requireCondStore()
            let command = FetchChangedFlagsCommand(identifierSet: uids, changedSince: changedSince)
            return try await primaryConnection.executeCommand(command)
        }
    }
}

extension Set where Element == NIOIMAPCore.Capability {
    /// Throws unless CONDSTORE, or QRESYNC (which implies it, RFC 7162 section 3.2.3), was advertised.
    func requireCondStore() throws {
        guard containsCondStoreCapability || containsQResyncCapability else {
            throw IMAPError.commandNotSupported("CONDSTORE not supported by server")
        }
    }
}
