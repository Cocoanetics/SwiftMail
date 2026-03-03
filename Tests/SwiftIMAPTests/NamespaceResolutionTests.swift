import Testing
@testable import SwiftMail

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
}
