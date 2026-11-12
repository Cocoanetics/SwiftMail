import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct NamespaceResolutionTests {
    @Test
    func defaultNamespaceUsesExistingPaths() {
        let namespace = NamespaceResponse(
            personal: [Namespace(prefix: "", delimiter: Character("/"))],
            otherUsers: [],
            shared: []
        )

        #expect(namespace.resolveMailboxPath("Sent") == "Sent")
        #expect(namespace.relativeMailboxName(from: "Sent") == "Sent")
        #expect(namespace.listingPatterns(for: "*") == ["*"])
    }

    @Test
    func prefixedPersonalNamespaceResolvesRelativePaths() {
        let namespace = NamespaceResponse(
            personal: [Namespace(prefix: "INBOX.", delimiter: Character("."))],
            otherUsers: [],
            shared: []
        )

        #expect(namespace.resolveMailboxPath("Sent") == "INBOX.Sent")
        #expect(namespace.resolveMailboxPath("INBOX.Trash") == "INBOX.Trash")
        #expect(namespace.relativeMailboxName(from: "INBOX.Drafts") == "Drafts")

        let patterns = namespace.listingPatterns(for: "*")
        #expect(patterns.contains("INBOX.*"))
        #expect(patterns.contains("INBOX"))
    }

    @Test
    func sharedNamespacePatternsIncludeSharedRoot() {
        let namespace = NamespaceResponse(
            personal: [Namespace(prefix: "", delimiter: Character("/"))],
            otherUsers: [],
            shared: [Namespace(prefix: "Shared/", delimiter: Character("/"))]
        )

        let patterns = namespace.listingPatterns(for: "*")
        #expect(patterns.contains("*"))
        #expect(patterns.contains("Shared/*"))
        #expect(patterns.contains("Shared"))
        #expect(namespace.relativeMailboxName(from: "Shared/Projects") == "Projects")
    }

    @Test
    func specialMailboxLookupHandlesPrefixedPaths() {
        let mailboxes = [
            Mailbox.Info(name: "INBOX.Sent", attributes: [], hierarchyDelimiter: "."),
            Mailbox.Info(name: "Shared/Trash", attributes: [], hierarchyDelimiter: "/"),
            Mailbox.Info(name: "INBOX.Drafts", attributes: [], hierarchyDelimiter: ".")
        ]

        #expect(mailboxes.sent?.name == "INBOX.Sent")
        #expect(mailboxes.trash?.name == "Shared/Trash")
        #expect(mailboxes.drafts?.name == "INBOX.Drafts")
    }

    /// RFC 2342 §6 / RFC 3501 §5.1: INBOX exists whatever the personal prefix, and need not
    /// sit inside the personal namespace. A full listing must ask for it.
    @Test(arguments: ["*", "%"])
    func personalPrefixOutsideInboxStillListsInbox(wildcard: String) {
        let namespace = NamespaceResponse(
            personal: [Namespace(prefix: "Mail/", delimiter: Character("/"))],
            otherUsers: [],
            shared: []
        )

        let patterns = namespace.listingPatterns(for: wildcard)
        #expect(patterns == ["Mail/" + wildcard, "Mail", "INBOX"])
        #expect(namespace.personalListingPatterns(for: wildcard).contains("INBOX"))
    }

    /// A pattern that already lists INBOX is not joined by a second one.
    @Test
    func inboxIsNotAskedForTwice() {
        let inboxPrefix = NamespaceResponse(
            personal: [Namespace(prefix: "INBOX.", delimiter: Character("."))],
            otherUsers: [],
            shared: []
        )
        #expect(inboxPrefix.listingPatterns(for: "*") == ["INBOX.*", "INBOX"])

        let lowercaseInboxPrefix = NamespaceResponse(
            personal: [Namespace(prefix: "inbox/", delimiter: Character("/"))],
            otherUsers: [],
            shared: []
        )
        #expect(lowercaseInboxPrefix.listingPatterns(for: "*") == ["inbox/*", "inbox"])

        let emptyPrefix = NamespaceResponse(
            personal: [Namespace(prefix: "", delimiter: Character("/"))],
            otherUsers: [],
            shared: [Namespace(prefix: "Shared/", delimiter: Character("/"))]
        )
        #expect(emptyPrefix.listingPatterns(for: "*") == ["*", "Shared/*", "Shared"])
    }

    /// A narrower wildcard is the caller's own filter; INBOX is not added to it.
    @Test
    func narrowWildcardDoesNotAddInbox() {
        let namespace = NamespaceResponse(
            personal: [Namespace(prefix: "Mail/", delimiter: Character("/"))],
            otherUsers: [],
            shared: []
        )
        #expect(namespace.listingPatterns(for: "Archive*") == ["Mail/Archive*"])
    }
}
