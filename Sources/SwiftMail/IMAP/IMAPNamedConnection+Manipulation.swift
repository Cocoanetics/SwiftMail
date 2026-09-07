import Foundation

extension IMAPNamedConnection {
    /// Copy messages to another mailbox.
    ///
    /// - Returns: A ``CopyUID`` with the server-verified source-to-destination UID mapping,
    ///   or `nil` when the server omits `COPYUID` (e.g. the server does not advertise UIDPLUS,
    ///   or a sequence-number-based copy was issued).
    /// - Throws: ``IMAPError/malformedCopyUIDAfterTaggedOK(_:)`` when the server completes
    ///   the command but supplies malformed or unverifiable COPYUID evidence. The COPY
    ///   completed and must not be resent.
    @discardableResult
    public func copy<T: MessageIdentifier>(
        messages identifierSet: MessageIdentifierSet<T>,
        to destinationMailbox: String
    ) async throws -> CopyUID? {
        let command = CopyCommand(
            identifierSet: identifierSet,
            destinationMailbox: resolveMailboxPath(destinationMailbox)
        )
        let copyUID = try await executeCommand(command)
        return try command.validate(copyUID: copyUID)
    }

    /// Update flags for messages.
    public func store<T: MessageIdentifier>(
        flags: [Flag],
        on identifierSet: MessageIdentifierSet<T>,
        operation: StoreData.StoreType
    ) async throws {
        let data = StoreData.flags(flags, operation)
        let command = StoreCommand(identifierSet: identifierSet, data: data)
        try await executeCommand(command)
    }

    /// Expunge messages marked with `\Deleted`.
    public func expunge() async throws {
        let command = ExpungeCommand()
        try await executeCommand(command)
    }

    /// Expunge specific messages marked with `\Deleted` using UIDPLUS.
    public func expunge(messages identifierSet: UIDSet) async throws {
        guard supportsUIDPlus else {
            throw IMAPError.commandNotSupported("UID EXPUNGE command not supported by server")
        }

        let command = UIDExpungeCommand(identifierSet: identifierSet)
        try await executeCommand(command)
    }

    /// Move messages using the established MOVE-or-COPY+STORE+EXPUNGE policy.
    @discardableResult
    public func move<T: MessageIdentifier>(
        messages identifierSet: MessageIdentifierSet<T>,
        to destinationMailbox: String
    ) async throws -> CopyUID? {
        try await move(
            messages: identifierSet,
            to: destinationMailbox,
            fallback: .copyStoreExpunge
        )
    }

    /// Move messages to another mailbox with an explicit fallback policy.
    ///
    /// Pass ``MoveFallbackPolicy/disabled`` to require MOVE without requiring UIDPLUS.
    ///
    /// - Returns: A ``CopyUID`` with the server-verified source-to-destination UID mapping,
    ///   or `nil` when the server omits `COPYUID`.
    /// - Throws: ``IMAPError/commandNotSupported(_:)`` before a manipulation command when
    ///   `fallback` is ``MoveFallbackPolicy/disabled`` and MOVE is not advertised; or
    ///   ``IMAPError/moveFailedAfterPossiblePartialCompletion(_:)`` when server state may
    ///   have changed but no trustworthy mapping is available; or
    ///   ``IMAPError/moveFailedAfterPartialCompletion(copyUID:reason:)`` when a tagged failure
    ///   follows a verified partial mapping, which callers must use to reconcile both mailboxes; or
    ///   ``IMAPError/moveFallbackFailedAfterCopy(copyUID:reason:)`` when fallback COPY succeeds
    ///   but source STORE or EXPUNGE does not complete; or
    ///   ``IMAPError/malformedCopyUIDAfterTaggedOK(_:)`` after a successful command with
    ///   malformed, conflicting, or unverifiable COPYUID evidence. A command that throws
    ///   the latter error completed and must not be resent.
    @discardableResult
    public func move<T: MessageIdentifier>(
        messages identifierSet: MessageIdentifierSet<T>,
        to destinationMailbox: String,
        fallback: MoveFallbackPolicy
    ) async throws -> CopyUID? {
        try await ensureAuthenticated()
        let capabilities = self.capabilities
        let useTargetedUIDExpunge = T.self == UID.self
            && capabilities.containsUIDPlusCapability

        if case .disabled = fallback {
            guard capabilities.containsMoveCapability else {
                throw IMAPError.commandNotSupported("MOVE command not supported by server")
            }
            return try await executeMove(messages: identifierSet, to: destinationMailbox)
        }

        if capabilities.containsMoveCapability
            && (T.self != UID.self || useTargetedUIDExpunge) {
            return try await executeMove(messages: identifierSet, to: destinationMailbox)
        }

        let copyUID = try await copy(messages: identifierSet, to: destinationMailbox)
        do {
            try await store(flags: [.deleted], on: identifierSet, operation: .add)
            try await expungeMoveFallback(
                messages: identifierSet,
                useTargetedUIDExpunge: useTargetedUIDExpunge
            )
            return copyUID
        } catch {
            throw IMAPError.moveFallbackFailed(after: copyUID, underlying: error)
        }
    }

    /// Move one message using the established MOVE-or-COPY+STORE+EXPUNGE policy.
    @discardableResult
    public func move<T: MessageIdentifier>(
        message identifier: T,
        to destinationMailbox: String
    ) async throws -> CopyUID? {
        try await move(
            message: identifier,
            to: destinationMailbox,
            fallback: .copyStoreExpunge
        )
    }

    /// Move a single message to another mailbox with an explicit fallback policy.
    ///
    /// - Returns: A ``CopyUID`` with the server-verified source-to-destination UID mapping,
    ///   or `nil` when the server omits `COPYUID`.
    @discardableResult
    public func move<T: MessageIdentifier>(
        message identifier: T,
        to destinationMailbox: String,
        fallback: MoveFallbackPolicy
    ) async throws -> CopyUID? {
        let set = MessageIdentifierSet<T>(identifier)
        return try await move(messages: set, to: destinationMailbox, fallback: fallback)
    }

    private func executeMove<T: MessageIdentifier>(
        messages identifierSet: MessageIdentifierSet<T>,
        to destinationMailbox: String
    ) async throws -> CopyUID? {
        let command = MoveCommand(
            identifierSet: identifierSet,
            destinationMailbox: resolveMailboxPath(destinationMailbox)
        )
        do {
            let copyUID = try await executeCommand(command)
            return try command.validate(copyUID: copyUID)
        } catch let error as IMAPError {
            throw command.validate(error: error)
        }
    }

    private func expungeMoveFallback<T: MessageIdentifier>(
        messages identifierSet: MessageIdentifierSet<T>,
        useTargetedUIDExpunge: Bool
    ) async throws {
        if useTargetedUIDExpunge {
            let uidSet = UIDSet(identifierSet.toArray().map { UID($0.value) })
            try await expunge(messages: uidSet)
        } else {
            try await expunge()
        }
    }
}
