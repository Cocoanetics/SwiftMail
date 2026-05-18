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
