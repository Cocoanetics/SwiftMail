import Foundation
@preconcurrency import NIOIMAPCore

extension IMAPNamedConnection {
    /// Fetch server capabilities.
    @discardableResult
    public func fetchCapabilities() async throws -> [Capability] {
        let result = try await connection.fetchCapabilities()
        recordActivity()
        return result
    }

    /// Enables extensions only on this named connection.
    ///
    /// Issue ENABLE after authentication and again if this connection is replaced.
    /// The return value contains exactly the capabilities confirmed by the server.
    ///
    /// - Throws: ``IMAPError/invalidArgument(_:)`` for an empty request,
    ///   ``IMAPError/commandNotSupported(_:)`` when ENABLE was not advertised, or
    ///   ``IMAPError/commandFailed(_:)`` when the server rejects the command.
    @discardableResult
    public func enable(_ capabilities: [Capability]) async throws -> [Capability] {
        try await ensureAuthenticated()
        let command = EnableCommand(capabilities: capabilities)
        try command.validate()
        guard self.capabilities.contains(.enable) else {
            throw IMAPError.commandNotSupported("ENABLE command not supported by server")
        }
        return try await executeCommand(command)
    }

    /// Select a mailbox for subsequent commands.
    @discardableResult
    public func select(mailbox mailboxName: String) async throws -> Mailbox.Selection {
        // Authenticate first so namespacesSnapshot is populated (or repopulated
        // after a reconnect) before we resolve the mailbox path.
        try await ensureAuthenticated()
        let command = SelectMailboxCommand(mailboxName: resolveMailboxPath(mailboxName))
        return try await executeCommand(command)
    }

    /// Compatibility alias for selecting a mailbox.
    @discardableResult
    public func selectMailbox(_ mailboxName: String) async throws -> Mailbox.Selection {
        try await select(mailbox: mailboxName)
    }

    /// Selects a mailbox with QRESYNC on this named connection.
    ///
    /// QRESYNC must already be enabled on this live connection. Compare the returned
    /// UIDVALIDITY with `uidValidity` before applying changes. If `highestModSequence`
    /// is nil, discard the stored modification-sequence checkpoint and fall back to
    /// ordinary synchronization. Otherwise, apply both deletion sets before replacing
    /// each message's full flag set. The returned message count already accounts for
    /// live deletions; do not subtract them again.
    ///
    /// - Throws: ``IMAPError/commandNotSupported(_:)`` when QRESYNC was not advertised,
    ///   ``IMAPError/invalidArgument(_:)`` for an invalid mailbox or checkpoint, or
    ///   ``IMAPError/selectFailed(_:)`` when the server rejects the selection.
    @discardableResult
    public func select(
        mailbox mailboxName: String,
        resyncingFrom uidValidity: UIDValidity,
        modificationSequence: ModificationSequenceValue
    ) async throws -> Mailbox.ResyncSelection {
        try await ensureAuthenticated()
        guard capabilities.contains(.qresync) else {
            throw IMAPError.commandNotSupported("QRESYNC not supported by server")
        }
        let command = ResyncSelectMailboxCommand(
            mailboxName: resolveMailboxPath(mailboxName),
            uidValidity: uidValidity,
            modificationSequence: modificationSequence
        )
        return try await executeCommand(command)
    }

    /// Compatibility alias for selecting a mailbox with QRESYNC.
    @discardableResult
    public func selectMailbox(
        _ mailboxName: String,
        resyncingFrom uidValidity: UIDValidity,
        modificationSequence: ModificationSequenceValue
    ) async throws -> Mailbox.ResyncSelection {
        try await select(
            mailbox: mailboxName,
            resyncingFrom: uidValidity,
            modificationSequence: modificationSequence
        )
    }

    /// Select a mailbox read-only using IMAP EXAMINE.
    ///
    /// The server enforces the read-only selection: STORE and EXPUNGE operations
    /// are not permitted while the mailbox remains selected this way.
    @discardableResult
    public func examineMailbox(_ mailboxName: String) async throws -> Mailbox.Selection {
        try await ensureAuthenticated()
        let command = ExamineMailboxCommand(mailboxName: resolveMailboxPath(mailboxName))
        return try await executeCommand(command)
    }

    /// Close the currently selected mailbox (expunges `\Deleted` messages).
    public func closeMailbox() async throws {
        let command = CloseCommand()
        try await executeCommand(command)
    }

    /// Unselect the currently selected mailbox without expunging.
    public func unselectMailbox() async throws {
        if !capabilities.contains(.unselect) {
            throw IMAPError.commandNotSupported("UNSELECT command not supported by server")
        }

        let command = UnselectCommand()
        try await executeCommand(command)
    }

    /// Retrieve mailbox status without selecting the mailbox.
    public func mailboxStatus(_ mailboxName: String) async throws -> Mailbox.Status {
        let attributes = mailboxStatusAttributes()
        let command = StatusCommand(mailboxName: resolveMailboxPath(mailboxName), attributes: attributes)
        let status: NIOIMAPCore.MailboxStatus = try await executeCommand(command)
        return Mailbox.Status(nio: status)
    }

    /// Pick the optional STATUS attributes supported by the server. Split out
    /// of `mailboxStatus` so the public API stays compact.
    private func mailboxStatusAttributes() -> [NIOIMAPCore.MailboxAttribute] {
        var attributes: [NIOIMAPCore.MailboxAttribute] = [
            .messageCount,
            .recentCount,
            .unseenCount
        ]

        if capabilities.contains(.uidPlus) {
            attributes.append(.uidNext)
            attributes.append(.uidValidity)
        }
        if capabilities.contains(.condStore) {
            attributes.append(.highestModificationSequence)
        }
        if capabilities.contains(.objectID) {
            attributes.append(.mailboxID)
        }
        if capabilities.contains(.status(.size)) {
            attributes.append(.size)
        }
        if capabilities.contains(.mailboxSpecificAppendLimit) {
            attributes.append(.appendLimit)
        }

        return attributes
    }

    /// List mailboxes.
    public func listMailboxes(wildcard: String = "*") async throws -> [Mailbox.Info] {
        if let namespaces = connection.namespacesSnapshot {
            let patterns = namespaces.listingPatterns(for: wildcard)
            var allMailboxes: [Mailbox.Info] = []
            var seenNames: Set<String> = []

            for pattern in patterns {
                let command = ListCommand(wildcard: pattern)
                let listed = try await executeCommand(command)
                for mailbox in listed where seenNames.insert(mailbox.name).inserted {
                    allMailboxes.append(mailbox)
                }
            }

            if !allMailboxes.isEmpty {
                return allMailboxes
            }
        }

        let command = ListCommand(wildcard: wildcard)
        return try await executeCommand(command)
    }

    /// Fetch server namespace information.
    public func fetchNamespaces() async throws -> NamespaceResponse {
        try await ensureAuthenticated()
        return try await connection.fetchNamespaces()
    }
}
