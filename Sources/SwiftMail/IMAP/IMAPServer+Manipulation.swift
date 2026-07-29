import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Message Manipulation Commands

extension IMAPServer {
    /**
     Moves messages to another mailbox.

     This method attempts to use the MOVE extension if available, falling back to
     COPY+EXPUNGE if necessary.

     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable

     - Parameters:
     - identifierSet: The set of messages to move
     - destinationMailbox: The name of the destination mailbox
     - Returns: A ``CopyUID`` with the server-verified source-to-destination UID mapping,
       or `nil` when the server omits `COPYUID` (e.g. the server does not advertise UIDPLUS).
     - Throws:
     - `IMAPError.moveFailed` if the move operation fails
     - `IMAPError.emptyIdentifierSet` if the identifier set is empty
     - Note: Logs move operations at info level with message count and destination
     */
    @discardableResult
    public func move<T: MessageIdentifier>(
        messages identifierSet: MessageIdentifierSet<T>,
        to destinationMailbox: String
    ) async throws -> CopyUID? {
        if capabilities.contains(.move) && (T.self != UID.self || capabilities.contains(.uidPlus)) {
            return try await executeMove(messages: identifierSet, to: destinationMailbox)
        } else {
            // Fall back to COPY + DELETE + targeted expunge when UIDPLUS is available.
            let copyUID = try await copy(messages: identifierSet, to: destinationMailbox)
            try await store(flags: [.deleted], on: identifierSet, operation: .add)
            try await expungeMoveFallback(messages: identifierSet)
            return copyUID
        }
    }

    /**
     Move a single message from the current mailbox to another mailbox
     - Parameters:
     - message: The message identifier to move
     - destinationMailbox: The name of the destination mailbox
     - Returns: A ``CopyUID`` with the server-verified source-to-destination UID mapping,
       or `nil` when the server omits `COPYUID`.
     - Throws: An error if the move operation fails
     */
    @discardableResult
    public func move<T: MessageIdentifier>(
        message identifier: T, to destinationMailbox: String
    ) async throws -> CopyUID? {
        let set = MessageIdentifierSet<T>(identifier)
        return try await move(messages: set, to: destinationMailbox)
    }

    /**
     Move an email identified by its header from the current mailbox to another mailbox
     - Parameters:
     - header: The email header of the message to move
     - destinationMailbox: The name of the destination mailbox
     - Returns: A ``CopyUID`` with the server-verified source-to-destination UID mapping,
       or `nil` when the server omits `COPYUID`.
     - Throws: An error if the move operation fails
     */
    @discardableResult
    public func move(header: MessageInfo, to destinationMailbox: String) async throws -> CopyUID? {
        if let uid = header.uid {
            return try await move(message: uid, to: destinationMailbox)
        } else {
            let sequenceNumber = header.sequenceNumber
            return try await move(message: sequenceNumber, to: destinationMailbox)
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
        return try await executeCommand(command)
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
        messages identifierSet: MessageIdentifierSet<T>
    ) async throws {
        if T.self == UID.self && capabilities.contains(.uidPlus) {
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
     - `IMAPError.moveFailed` if the move operation fails
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
        return try await executeCommand(command)
    }
}
