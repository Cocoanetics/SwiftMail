import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Special-Use Mailboxes

extension IMAPServer {
    /**
     Lists mailboxes with special-use attributes.

     Special-use mailboxes are those designated for specific purposes like
     Sent, Drafts, Trash, etc., as defined in RFC 6154.

     - Returns: An array of special-use mailbox information
     - Throws:
     - `IMAPError.commandNotSupported` if SPECIAL-USE is not supported
     - `IMAPError.commandFailed` if the list operation fails
     - Note: Logs special mailbox detection at info level
     */
    @discardableResult
    public func listSpecialUseMailboxes() async throws -> [Mailbox.Info] {
        let supportsSpecialUse = capabilities.contains(NIOIMAPCore.Capability("SPECIAL-USE"))

        // Get all mailboxes and store them
        let allMailboxes = try await listMailboxes()
        updateMailboxes(allMailboxes)

        var specialFolders: [Mailbox.Info]
        var foundExplicitInbox: Bool

        if supportsSpecialUse {
            (specialFolders, foundExplicitInbox) = try await detectSpecialFoldersViaSpecialUse()
        } else {
            (specialFolders, foundExplicitInbox) = detectSpecialFoldersByName(mailboxes: allMailboxes)
        }

        // Per IMAP spec, INBOX always exists - if no explicit inbox was found, add it
        if !foundExplicitInbox, let inbox = makeImplicitInboxEntry(from: allMailboxes) {
            specialFolders.append(inbox)
        }

        updateSpecialMailboxes(specialFolders)
        return specialFolders
    }

    // MARK: - Detection Helpers

    /// Use the IMAP SPECIAL-USE extension to identify mailboxes.
    private func detectSpecialFoldersViaSpecialUse() async throws -> (folders: [Mailbox.Info], foundInbox: Bool) {
        let command = ListCommand(returnOptions: [.specialUse])
        let mailboxesWithAttributes = try await executeCommand(command)

        var specialFolders: [Mailbox.Info] = []
        var foundExplicitInbox = false

        for mailbox in mailboxesWithAttributes where hasSpecialUseAttribute(mailbox) {
            specialFolders.append(mailbox)
            if mailbox.attributes.contains(.inbox) {
                foundExplicitInbox = true
            }
        }

        return (specialFolders, foundExplicitInbox)
    }

    /// Whether a mailbox has any recognized SPECIAL-USE attribute.
    private func hasSpecialUseAttribute(_ mailbox: Mailbox.Info) -> Bool {
        let attributes = mailbox.attributes
        return attributes.contains(.inbox)
            || attributes.contains(.trash)
            || attributes.contains(.archive)
            || attributes.contains(.sent)
            || attributes.contains(.drafts)
            || attributes.contains(.junk)
            || attributes.contains(.flagged)
    }

    /// Fallback detection based on common folder names when the server
    /// does not advertise SPECIAL-USE.
    private func detectSpecialFoldersByName(
        mailboxes: [Mailbox.Info]
    ) -> (folders: [Mailbox.Info], foundInbox: Bool) {
        var specialFolders: [Mailbox.Info] = []
        var foundExplicitInbox = false

        for mailbox in mailboxes {
            var attributes = mailbox.attributes
            var hasSpecialUse = false

            if mailbox.attributes.contains(.inbox) {
                foundExplicitInbox = true
                hasSpecialUse = true
            } else {
                hasSpecialUse = applyNameBasedAttribute(for: mailbox, into: &attributes) || hasSpecialUse
            }

            hasSpecialUse = applyGmailSpecialAttribute(for: mailbox, into: &attributes) || hasSpecialUse

            if hasSpecialUse {
                specialFolders.append(
                    Mailbox.Info(
                        name: mailbox.name,
                        attributes: attributes,
                        hierarchyDelimiter: mailbox.hierarchyDelimiter
                    )
                )
            }
        }

        return (specialFolders, foundExplicitInbox)
    }

    /// Apply name-pattern-based heuristics for common folder names.
    /// Returns whether a special-use attribute was inserted.
    private func applyNameBasedAttribute(
        for mailbox: Mailbox.Info,
        into attributes: inout Mailbox.Info.Attributes
    ) -> Bool {
        let nameLower = normalizedMailboxName(mailbox.name).lowercased()

        if nameLower.contains("trash") || nameLower.contains("deleted") {
            attributes.insert(.trash)
            return true
        }
        if nameLower.contains("sent") {
            attributes.insert(.sent)
            return true
        }
        if nameLower.contains("draft") {
            attributes.insert(.drafts)
            return true
        }
        if nameLower.contains("junk") || nameLower.contains("spam") {
            attributes.insert(.junk)
            return true
        }
        if nameLower.contains("archive") || (nameLower.contains("all") && nameLower.contains("mail")) {
            attributes.insert(.archive)
            return true
        }
        if nameLower.contains("starred") || nameLower.contains("flagged") {
            attributes.insert(.flagged)
            return true
        }
        return false
    }

    /// Apply Gmail-specific folder name detection (e.g. `[Gmail]/Sent Mail`).
    /// Returns whether a special-use attribute was inserted.
    private func applyGmailSpecialAttribute(
        for mailbox: Mailbox.Info,
        into attributes: inout Mailbox.Info.Attributes
    ) -> Bool {
        let normalizedName = normalizedMailboxName(mailbox.name)
        let matchesGmail: (String, String) -> Bool = { gmailName, plainName in
            normalizedName.caseInsensitiveCompare(gmailName) == .orderedSame
                || normalizedName.caseInsensitiveCompare(plainName) == .orderedSame
        }

        if matchesGmail("[Gmail]/Trash", "Trash") {
            attributes.insert(.trash)
            return true
        }
        if matchesGmail("[Gmail]/Sent Mail", "Sent Mail") {
            attributes.insert(.sent)
            return true
        }
        if matchesGmail("[Gmail]/Drafts", "Drafts") {
            attributes.insert(.drafts)
            return true
        }
        if matchesGmail("[Gmail]/Spam", "Spam") {
            attributes.insert(.junk)
            return true
        }
        if matchesGmail("[Gmail]/All Mail", "All Mail") {
            attributes.insert(.archive)
            return true
        }
        if matchesGmail("[Gmail]/Starred", "Starred") {
            attributes.insert(.flagged)
            return true
        }
        return false
    }

    /// Produce an implicit INBOX entry when none of the special folders
    /// was already flagged as the inbox.
    private func makeImplicitInboxEntry(from mailboxes: [Mailbox.Info]) -> Mailbox.Info? {
        guard let inboxMailbox = mailboxes.first(where: { $0.name.caseInsensitiveCompare("INBOX") == .orderedSame })
        else {
            return nil
        }

        var inboxAttributes = inboxMailbox.attributes
        inboxAttributes.insert(.inbox)

        return Mailbox.Info(
            name: inboxMailbox.name,
            attributes: inboxAttributes,
            hierarchyDelimiter: inboxMailbox.hierarchyDelimiter
        )
    }
}
