import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Special Folder Operations

public extension IMAPServer {
    /// Ensures special-use mailboxes and the general mailbox list have been fetched.
    /// Called automatically by convenience folder operations so callers don't need
    /// to manually call `listSpecialUseMailboxes()` first.
    internal func ensureMailboxesLoaded() async throws {
        if mailboxes.isEmpty {
            // listSpecialUseMailboxes also populates self.mailboxes internally
            try await listSpecialUseMailboxes()
        } else if specialMailboxes.isEmpty {
            try await listSpecialUseMailboxes()
        }
    }

    /**
     Move messages to the trash folder

     Automatically fetches special-use mailboxes if they haven't been loaded yet.
     Falls back to a mailbox named "Trash" if the server doesn't advertise SPECIAL-USE.

     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable

     - Parameter identifierSet: The set of messages to move
     - Throws: An error if the move operation fails or trash folder is not found
     */
    func moveToTrash(messages identifierSet: MessageIdentifierSet<some MessageIdentifier>) async throws {
        try await ensureMailboxesLoaded()
        try await move(messages: identifierSet, to: trashFolder.name)
    }

    /**
     Archive messages by marking them as seen and moving them to the archive folder

     Automatically fetches special-use mailboxes if they haven't been loaded yet.
     Falls back to a mailbox named "Archive" if the server doesn't advertise SPECIAL-USE.

     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable

     - Parameter identifierSet: The set of messages to archive
     - Throws: An error if the archive operation fails or archive folder is not found
     */
    func archive(messages identifierSet: MessageIdentifierSet<some MessageIdentifier>) async throws {
        try await ensureMailboxesLoaded()
        try await store(flags: [.seen], on: identifierSet, operation: .add)
        try await move(messages: identifierSet, to: archiveFolder.name)
    }

    /**
     Mark messages as junk by moving them to the junk folder

     Automatically fetches special-use mailboxes if they haven't been loaded yet.
     Falls back to a mailbox named "Junk" or "Spam" if the server doesn't advertise SPECIAL-USE.

     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable

     - Parameter identifierSet: The set of messages to mark as junk
     - Throws: An error if the operation fails or junk folder is not found
     */
    func markAsJunk(messages identifierSet: MessageIdentifierSet<some MessageIdentifier>) async throws {
        try await ensureMailboxesLoaded()
        try await move(messages: identifierSet, to: junkFolder.name)
    }

    /**
      Save messages as drafts by adding the draft flag and moving them to the drafts folder

      The generic type T determines the identifier type:
      - Use `SequenceNumber` for temporary message numbers that may change
      - Use `UID` for permanent message identifiers that remain stable

      - Parameter identifierSet: The set of messages to save as drafts
      - Throws: An error if the operation fails or drafts folder is not found
     */
    func saveAsDraft(messages identifierSet: MessageIdentifierSet<some MessageIdentifier>) async throws {
        try await store(flags: [.draft], on: identifierSet, operation: .add)
        try await move(messages: identifierSet, to: draftsFolder.name)
    }
}
