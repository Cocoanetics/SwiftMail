import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Message Manipulation Commands

extension IMAPServer {
    /// Moves messages using the established MOVE-or-COPY+STORE+EXPUNGE policy.
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

    /**
     Moves messages to another mailbox.

     Pass ``MoveFallbackPolicy/disabled`` to require MOVE and refuse before emitting
     a manipulation command when the extension is unavailable. The disabled policy
     does not require UIDPLUS.

     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable

     - Parameters:
     - identifierSet: The set of messages to move
     - destinationMailbox: The name of the destination mailbox
     - fallback: Whether COPY+STORE+EXPUNGE fallback is allowed.
     - Returns: A ``CopyUID`` with the server-verified source-to-destination UID mapping,
       or `nil` when the server omits `COPYUID` (e.g. the server does not advertise UIDPLUS).
     - Throws:
     - ``IMAPError/moveFailedAfterPossiblePartialCompletion(_:)`` when MOVE or a fallback
       may have changed server state but no trustworthy mapping is available; do not retry
     - ``IMAPError/moveFailedAfterPartialCompletion(copyUID:reason:)`` when a tagged failure
       follows a verified partial mapping; reconcile both mailboxes before deciding whether to retry
     - ``IMAPError/moveFallbackFailedAfterCopy(copyUID:reason:)`` when fallback COPY succeeds
       but a later STORE or EXPUNGE fails; destination copies are verified, source state is unknown
     - `IMAPError.emptyIdentifierSet` if the identifier set is empty
     - ``IMAPError/commandNotSupported(_:)`` before a manipulation command when `fallback`
       is ``MoveFallbackPolicy/disabled`` and MOVE is not advertised
     - ``IMAPError/malformedCopyUIDAfterTaggedOK(_:)`` after a successful command with
       malformed, conflicting, or unverifiable COPYUID evidence; the command completed and
       must not be resent
     - Note: Logs move operations at info level with message count and destination
     */
    @discardableResult
    public func move<T: MessageIdentifier>(
        messages identifierSet: MessageIdentifierSet<T>,
        to destinationMailbox: String,
        fallback: MoveFallbackPolicy
    ) async throws -> CopyUID? {
        try await ensurePrimaryConnectionAuthenticated()
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

        // Preserve the existing fallback, including targeted UID EXPUNGE when UIDPLUS is available.
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

    /// Moves one message using the established MOVE-or-COPY+STORE+EXPUNGE policy.
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

    /**
     Move a single message from the current mailbox to another mailbox
     - Parameters:
     - message: The message identifier to move
     - destinationMailbox: The name of the destination mailbox
     - fallback: Whether COPY+STORE+EXPUNGE fallback is allowed.
     - Returns: A ``CopyUID`` with the server-verified source-to-destination UID mapping,
       or `nil` when the server omits `COPYUID`.
     - Throws: An error if the move operation fails
     */
    @discardableResult
    public func move<T: MessageIdentifier>(
        message identifier: T,
        to destinationMailbox: String,
        fallback: MoveFallbackPolicy
    ) async throws -> CopyUID? {
        let set = MessageIdentifierSet<T>(identifier)
        return try await move(messages: set, to: destinationMailbox, fallback: fallback)
    }

    /// Moves the message identified by `header` using the established fallback policy.
    @discardableResult
    public func move(
        header: MessageInfo,
        to destinationMailbox: String
    ) async throws -> CopyUID? {
        try await move(
            header: header,
            to: destinationMailbox,
            fallback: .copyStoreExpunge
        )
    }

    /**
     Move an email identified by its header from the current mailbox to another mailbox
     - Parameters:
     - header: The email header of the message to move
     - destinationMailbox: The name of the destination mailbox
     - fallback: Whether COPY+STORE+EXPUNGE fallback is allowed.
     - Returns: A ``CopyUID`` with the server-verified source-to-destination UID mapping,
       or `nil` when the server omits `COPYUID`.
     - Throws: An error if the move operation fails
     */
    @discardableResult
    public func move(
        header: MessageInfo,
        to destinationMailbox: String,
        fallback: MoveFallbackPolicy
    ) async throws -> CopyUID? {
        if let uid = header.uid {
            return try await move(message: uid, to: destinationMailbox, fallback: fallback)
        } else {
            let sequenceNumber = header.sequenceNumber
            return try await move(message: sequenceNumber, to: destinationMailbox, fallback: fallback)
        }
    }

    /**
     Copies messages to another mailbox.

     - Parameters:
     - identifierSet: The set of messages to copy
     - destinationMailbox: The name of the destination mailbox
     - Returns: A ``CopyUID`` with the server-verified source-to-destination UID mapping,
       or `nil` when the server omits `COPYUID` (e.g. the server does not advertise UIDPLUS,
       or a sequence-number-based copy was issued).
     - Throws:
     - `IMAPError.copyFailed` if the copy operation fails
     - `IMAPError.emptyIdentifierSet` if the identifier set is empty
     - ``IMAPError/malformedCopyUIDAfterTaggedOK(_:)`` after a successful COPY with
       malformed or unverifiable COPYUID evidence; the COPY completed and must not be resent
     */
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

    /**
     Updates flags on messages.

     This method can add, remove, or replace flags on messages. Common flags include:
     - \Seen (message has been read)
     - \Answered (message has been replied to)
     - \Flagged (message is marked important)
     - \Deleted (message is marked for deletion)
     - \Draft (message is a draft)

     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable

     - Parameters:
     - flags: The flags to modify
     - identifierSet: The set of messages to update
     - operation: The type of update operation (add, remove, or set)
     - Throws:
     - `IMAPError.storeFailed` if the flag update fails
     - `IMAPError.emptyIdentifierSet` if the identifier set is empty
     - Note: Logs flag updates at debug level with operation type and message count
     */
    public func store<T: MessageIdentifier>(
        flags: [Flag],
        on identifierSet: MessageIdentifierSet<T>,
        operation: StoreData.StoreType
    ) async throws {
        let storeData = StoreData.flags(flags, operation)
        let command = StoreCommand(identifierSet: identifierSet, data: storeData)
        try await executeCommand(command)
    }

    /**
     Permanently removes messages marked for deletion.

     This method removes all messages with the \Deleted flag from the selected mailbox.
     The operation cannot be undone.

     - Throws: `IMAPError.expungeFailed` if the expunge operation fails
     - Note: Logs expunge operations at info level with number of messages removed
     */
    public func expunge() async throws {
        let command = ExpungeCommand()
        try await executeCommand(command)
    }

    /// Permanently removes specific deleted messages by UID when UIDPLUS is available.
    public func expunge(messages identifierSet: UIDSet) async throws {
        guard supportsUIDPlus else {
            throw IMAPError.commandNotSupported("UID EXPUNGE command not supported by server")
        }

        let command = UIDExpungeCommand(identifierSet: identifierSet)
        try await executeCommand(command)
    }

    func expungeMoveFallback<T: MessageIdentifier>(
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

    /**
     Execute a move command

     This method executes a move command using the MOVE extension.

     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable

     - Parameters:
     - identifierSet: The set of messages to move
     - destinationMailbox: The name of the destination mailbox
     - Throws:
     - ``IMAPError/moveFailedAfterPossiblePartialCompletion(_:)`` when the move may have
       changed server state without a trustworthy mapping
     - `IMAPError.emptyIdentifierSet` if the identifier set is empty
     - Note: Logs move operations at debug level
     */
    func executeMove<T: MessageIdentifier>(
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
}
