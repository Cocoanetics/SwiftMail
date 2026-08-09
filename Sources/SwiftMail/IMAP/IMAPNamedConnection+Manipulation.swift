import Foundation

extension IMAPNamedConnection {
    /// Copy messages to another mailbox.
    ///
    /// - Returns: A ``CopyUID`` with the server-verified source-to-destination UID mapping,
    ///   or `nil` when the server omits `COPYUID` (e.g. the server does not advertise UIDPLUS,
    ///   or a sequence-number-based copy was issued).
    /// - Throws: ``IMAPError/malformedCopyUIDAfterTaggedOK(_:)`` when the server completes
    ///   the command but supplies malformed COPYUID evidence. The COPY completed and must
    ///   not be resent.
    @discardableResult
    public func copy<T: MessageIdentifier>(
        messages identifierSet: MessageIdentifierSet<T>,
        to destinationMailbox: String
    ) async throws -> CopyUID? {
        let command = CopyCommand(
            identifierSet: identifierSet,
            destinationMailbox: resolveMailboxPath(destinationMailbox)
        )
        return try await executeCommand(command)
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

    /// Move messages to another mailbox.
    ///
    /// The default retains the existing MOVE-or-COPY+STORE+EXPUNGE behavior. Pass
    /// ``MoveFallbackPolicy/disabled`` to require MOVE without requiring UIDPLUS.
    ///
    /// - Returns: A ``CopyUID`` with the server-verified source-to-destination UID mapping,
    ///   or `nil` when the server omits `COPYUID`.
    /// - Throws: ``IMAPError/commandNotSupported(_:)`` before a manipulation command when
    ///   `fallback` is ``MoveFallbackPolicy/disabled`` and MOVE is not advertised; or
    ///   ``IMAPError/malformedCopyUIDAfterTaggedOK(_:)`` after a successful command with
    ///   malformed or conflicting COPYUID evidence. A command that throws the latter error
    ///   completed and must not be resent.
    @discardableResult
    public func move<T: MessageIdentifier>(
        messages identifierSet: MessageIdentifierSet<T>,
        to destinationMailbox: String,
        fallback: MoveFallbackPolicy = .copyStoreExpunge
    ) async throws -> CopyUID? {
        if case .disabled = fallback {
            guard capabilities.containsMoveCapability else {
                throw IMAPError.commandNotSupported("MOVE command not supported by server")
            }
            return try await executeMove(messages: identifierSet, to: destinationMailbox)
        }

        if capabilities.containsMoveCapability
            && (T.self != UID.self || capabilities.contains(.uidPlus)) {
            return try await executeMove(messages: identifierSet, to: destinationMailbox)
        }

        let copyUID = try await copy(messages: identifierSet, to: destinationMailbox)
        try await store(flags: [.deleted], on: identifierSet, operation: .add)
        try await expungeMoveFallback(messages: identifierSet)
        return copyUID
    }

    /// Move a single message to another mailbox.
    ///
    /// - Returns: A ``CopyUID`` with the server-verified source-to-destination UID mapping,
    ///   or `nil` when the server omits `COPYUID`.
    @discardableResult
    public func move<T: MessageIdentifier>(
        message identifier: T,
        to destinationMailbox: String,
        fallback: MoveFallbackPolicy = .copyStoreExpunge
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
        return try await executeCommand(command)
    }

    private func expungeMoveFallback<T: MessageIdentifier>(
        messages identifierSet: MessageIdentifierSet<T>
    ) async throws {
        if T.self == UID.self && capabilities.contains(.uidPlus) {
            let uidSet = UIDSet(identifierSet.toArray().map { UID($0.value) })
            try await expunge(messages: uidSet)
        } else {
            try await expunge()
        }
    }
}
