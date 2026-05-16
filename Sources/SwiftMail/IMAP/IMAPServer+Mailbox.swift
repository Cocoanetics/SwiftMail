import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Mailbox Commands

public extension IMAPServer {
    /**
     Create a new mailbox on the server

     This method creates a new mailbox (folder) with the specified name.
     Use forward slashes to create hierarchical mailboxes (e.g., "Work/Projects").

     - Parameter mailboxName: The name of the mailbox to create
     - Throws:
     - `IMAPError.commandFailed` if the mailbox cannot be created
     - `IMAPError.connectionFailed` if not connected
     - Note: Logs mailbox creation at debug level
     */
    func createMailbox(_ mailboxName: String) async throws {
        let command = CreateMailboxCommand(mailboxName: resolveMailboxPath(mailboxName))
        try await executeCommand(command)
    }

    /**
     Select a mailbox

     This method selects a mailbox and makes it the current mailbox for subsequent
     operations. Only one mailbox can be selected at a time.

     - Parameter mailboxName: The name of the mailbox to select
     - Returns: Status information about the selected mailbox
     - Throws:
     - `IMAPError.selectFailed` if the mailbox cannot be selected
     - `IMAPError.connectionFailed` if not connected
     - Note: Logs mailbox selection at debug level
     - Important: The returned status does not include an unseen count, as this is not provided by the
     IMAP SELECT command.
     To get the count of unseen messages, use `mailboxStatus("INBOX").unseenCount` instead.
     */
    @discardableResult func selectMailbox(_ mailboxName: String) async throws -> Mailbox.Selection {
        let command = SelectMailboxCommand(mailboxName: resolveMailboxPath(mailboxName))
        return try await executeCommand(command)
    }

    /**
     Close the currently selected mailbox

     This method closes the currently selected mailbox and expunges any messages
     marked for deletion. To close without expunging, use unselectMailbox() instead.

     - Throws:
     - `IMAPError.closeFailed` if the close operation fails
     - `IMAPError.connectionFailed` if not connected
     - Note: Logs mailbox closure at debug level
     */
    func closeMailbox() async throws {
        let command = CloseCommand()
        try await executeCommand(command)
    }

    /**
     Unselect the currently selected mailbox without expunging deleted messages

     This is an IMAP extension command (RFC 3691) that might not be supported by all servers.
     If the server does not support UNSELECT, an IMAPError will be thrown.

     - Throws:
     - `IMAPError.commandNotSupported` if UNSELECT is not supported
     - `IMAPError.unselectFailed` if the unselect operation fails
     - `IMAPError.connectionFailed` if not connected
     - Note: Logs mailbox unselection at debug level
     */
    func unselectMailbox() async throws {
        // Check if the server supports UNSELECT capability
        if !capabilities.contains(.unselect) {
            throw IMAPError.commandNotSupported("UNSELECT command not supported by server")
        }

        let command = UnselectCommand()
        try await executeCommand(command)
    }

    /**
     Get status information about a mailbox without selecting it

     This method uses the IMAP STATUS command to retrieve standard attributes of a mailbox
     without having to select it. It automatically requests standard attributes (MESSAGES,
     RECENT, UNSEEN) and optional attributes based on server capabilities.

     - Parameter mailboxName: The name of the mailbox to get status for
     - Returns: Status information about the mailbox
     - Throws:
     - `IMAPError.commandFailed` if the status operation fails
     - `IMAPError.connectionFailed` if not connected
     - Note: Logs status retrieval at debug level
     - Important: Many servers emit a warning (e.g. `OK [CLIENTBUG] Status on selected mailbox`) when
     `STATUS` is issued for the currently selected mailbox. Call this method when no mailbox is selected
     (before `selectMailbox(_)`) or after `unselectMailbox()`/`closeMailbox()` to avoid the warning.
     */
    func mailboxStatus(_ mailboxName: String) async throws -> Mailbox.Status {
        // Always request standard attributes
        var attributes: [NIOIMAPCore.MailboxAttribute] = [
            .messageCount,
            .recentCount,
            .unseenCount
        ]

        // Add optional attributes based on server capabilities
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

        let command = StatusCommand(mailboxName: resolveMailboxPath(mailboxName), attributes: attributes)
        let status: NIOIMAPCore.MailboxStatus = try await executeCommand(command)
        return Mailbox.Status(nio: status)
    }
}
