import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Special Folder Accessors

extension IMAPServer {
    /**
     Get the inbox folder or throw if not found

     - Returns: The inbox folder information
     - Throws: `UndefinedFolderError.inbox` if the inbox folder is not found
     */
    public var inboxFolder: Mailbox.Info {
        get throws {
            guard let inbox = specialMailboxes.inbox ?? mailboxes.inbox else {
                throw UndefinedFolderError.inbox
            }
            return inbox
        }
    }

    /**
     Get the trash folder or throw if not found

     Checks special-use mailboxes first, then falls back to the general mailbox list
     (which includes name-based matching for common folder names like "Trash").

     - Returns: The trash folder information
     - Throws: `UndefinedFolderError.trash` if the trash folder is not found
     */
    public var trashFolder: Mailbox.Info {
        get throws {
            if let trash = specialMailboxes.trash ?? mailboxes.trash {
                return trash
            }
            throw UndefinedFolderError.trash
        }
    }

    /**
     Get the archive folder or throw if not found

     Checks special-use mailboxes first, then falls back to the general mailbox list
     (which includes name-based matching for common folder names like "Archive").

     - Returns: The archive folder information
     - Throws: `UndefinedFolderError.archive` if the archive folder is not found
     */
    public var archiveFolder: Mailbox.Info {
        get throws {
            if let archive = specialMailboxes.archive ?? mailboxes.archive {
                return archive
            }
            throw UndefinedFolderError.archive
        }
    }

    /**
     Get the sent folder or throw if not found

     Checks special-use mailboxes first, then falls back to the general mailbox list
     (which includes name-based matching for common folder names like "Sent").

     - Returns: The sent folder information
     - Throws: `UndefinedFolderError.sent` if the sent folder is not found
     */
    public var sentFolder: Mailbox.Info {
        get throws {
            if let sent = specialMailboxes.sent ?? mailboxes.sent {
                return sent
            }
            throw UndefinedFolderError.sent
        }
    }

    /**
     Get the drafts folder or throw if not found

     Checks special-use mailboxes first, then falls back to the general mailbox list
     (which includes name-based matching for common folder names like "Drafts").

     - Returns: The drafts folder information
     - Throws: `UndefinedFolderError.drafts` if the drafts folder is not found
     */
    public var draftsFolder: Mailbox.Info {
        get throws {
            if let drafts = specialMailboxes.drafts ?? mailboxes.drafts {
                return drafts
            }
            throw UndefinedFolderError.drafts
        }
    }

    /**
     Get the junk folder or throw if not found

     Checks special-use mailboxes first, then falls back to the general mailbox list
     (which includes name-based matching for common folder names like "Junk" or "Spam").

     - Returns: The junk folder information
     - Throws: `UndefinedFolderError.junk` if the junk folder is not found
     */
    public var junkFolder: Mailbox.Info {
        get throws {
            if let junk = specialMailboxes.junk ?? mailboxes.junk {
                return junk
            }
            throw UndefinedFolderError.junk
        }
    }
}
