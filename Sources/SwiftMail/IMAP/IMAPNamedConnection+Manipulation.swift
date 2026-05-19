import Foundation

extension IMAPNamedConnection {
    /// Copy messages to another mailbox.
    public func copy<T: MessageIdentifier>(
        messages identifierSet: MessageIdentifierSet<T>,
        to destinationMailbox: String
    ) async throws {
        let command = CopyCommand(
            identifierSet: identifierSet,
            destinationMailbox: resolveMailboxPath(destinationMailbox)
        )
        try await executeCommand(command)
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

    /// Move messages to another mailbox (uses MOVE if supported, otherwise COPY+STORE+EXPUNGE).
    public func move<T: MessageIdentifier>(
        messages identifierSet: MessageIdentifierSet<T>,
        to destinationMailbox: String
    ) async throws {
        if capabilities.contains(.move) && (T.self != UID.self || capabilities.contains(.uidPlus)) {
            try await executeMove(messages: identifierSet, to: destinationMailbox)
        } else {
            try await copy(messages: identifierSet, to: destinationMailbox)
            try await store(flags: [.deleted], on: identifierSet, operation: .add)
            try await expungeMoveFallback(messages: identifierSet)
        }
    }

    /// Move a single message to another mailbox.
    public func move<T: MessageIdentifier>(message identifier: T, to destinationMailbox: String) async throws {
        let set = MessageIdentifierSet<T>(identifier)
        try await move(messages: set, to: destinationMailbox)
    }

    private func executeMove<T: MessageIdentifier>(
        messages identifierSet: MessageIdentifierSet<T>,
        to destinationMailbox: String
    ) async throws {
        let command = MoveCommand(
            identifierSet: identifierSet,
            destinationMailbox: resolveMailboxPath(destinationMailbox)
        )
        try await executeCommand(command)
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
