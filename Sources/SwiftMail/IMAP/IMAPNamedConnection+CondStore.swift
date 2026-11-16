import Foundation

// MARK: - CONDSTORE (RFC 7162 section 3.1)

extension IMAPNamedConnection {
    /// Selects a mailbox on this named connection, optionally with the RFC 7162 `CONDSTORE`
    /// select parameter.
    ///
    /// Behaves like ``IMAPServer/selectMailbox(_:enablingCondStore:)`` on this connection.
    ///
    /// - Throws: ``IMAPError/commandNotSupported(_:)`` when `enablingCondStore` is true and neither
    ///   CONDSTORE nor QRESYNC was advertised (nothing is sent), or ``IMAPError/selectFailed(_:)``
    ///   when the server rejects the selection.
    @discardableResult
    public func select(mailbox mailboxName: String, enablingCondStore: Bool) async throws -> Mailbox.Selection {
        try await withAuthenticatedOperation { [self] in
            if enablingCondStore {
                try capabilities.requireCondStore()
            }
            let command = SelectMailboxCommand(
                mailboxName: resolveMailboxPath(mailboxName),
                condStore: enablingCondStore
            )
            return try await executeCommand(command)
        }
    }

    /// Compatibility alias for ``select(mailbox:enablingCondStore:)``.
    @discardableResult
    public func selectMailbox(_ mailboxName: String, enablingCondStore: Bool) async throws -> Mailbox.Selection {
        try await select(mailbox: mailboxName, enablingCondStore: enablingCondStore)
    }

    /// Fetches the flags of the messages in `uids` whose modification sequence is greater than
    /// `modificationSequence`, on this named connection.
    ///
    /// Behaves like ``IMAPServer/fetchFlagsChangedSince(_:modificationSequence:)`` on this connection.
    /// A `uids` set holding ``UID/latest`` (sent as `*`) must be `1:*`; any other such set throws
    /// ``IMAPError/invalidArgument(_:)`` before anything is sent.
    ///
    /// - Throws: The same errors as ``IMAPServer/fetchFlagsChangedSince(_:modificationSequence:)``.
    public func fetchFlagsChangedSince(
        _ uids: UIDSet,
        modificationSequence: UInt64
    ) async throws -> [ChangedMessageFlags] {
        let changedSince = try ResyncSelectMailboxCommand.modificationSequence(fromRawValue: modificationSequence)
        return try await withAuthenticatedOperation { [self] in
            try capabilities.requireCondStore()
            let command = FetchChangedFlagsCommand(identifierSet: uids, changedSince: changedSince)
            return try await executeCommand(command)
        }
    }
}
