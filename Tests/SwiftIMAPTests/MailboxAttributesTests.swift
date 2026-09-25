import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite
struct MailboxAttributesTests {
    @Test
    func testAllAndImportantSpecialUseAttributesAreKept() {
        // Gmail marks All Mail with \All and Important with \Important (RFC 6154,
        // RFC 8457). Mailbox names are localised ("[Google Mail]/Alle Nachrichten"),
        // so the attribute is the only reliable way to find these mailboxes.
        let allMail = Mailbox.Info.Attributes(from: [
            .hasNoChildren, NIOIMAPCore.MailboxInfo.Attribute("\\All")
        ])
        #expect(allMail.contains(.all))
        #expect(allMail.contains(.hasNoChildren))
        #expect(!allMail.contains(.important))

        let important = Mailbox.Info.Attributes(from: [NIOIMAPCore.MailboxInfo.Attribute("\\Important")])
        #expect(important.contains(.important))
        #expect(!important.contains(.all))
    }

    @Test
    func testExistingSpecialUseAttributesStillMap() {
        let sent = Mailbox.Info.Attributes(from: [NIOIMAPCore.MailboxInfo.Attribute("\\Sent")])
        #expect(sent == [.sent])
        let junk = Mailbox.Info.Attributes(from: [NIOIMAPCore.MailboxInfo.Attribute("\\Junk")])
        #expect(junk == [.junk])
    }

    @Test
    func testAttributeMatchingIsExactAndCaseInsensitive() {
        // IMAP attributes are case-insensitive; matching must not be a substring search.
        #expect(Mailbox.Info.Attributes(from: [NIOIMAPCore.MailboxInfo.Attribute("\\all")]) == [.all])
        #expect(Mailbox.Info.Attributes(from: [NIOIMAPCore.MailboxInfo.Attribute("\\IMPORTANT")]) == [.important])
        #expect(Mailbox.Info.Attributes(from: [NIOIMAPCore.MailboxInfo.Attribute("\\sent")]) == [.sent])
        #expect(Mailbox.Info.Attributes(from: [NIOIMAPCore.MailboxInfo.Attribute("\\Alligator")]).isEmpty)
        #expect(Mailbox.Info.Attributes(from: [NIOIMAPCore.MailboxInfo.Attribute("\\Archived")]).isEmpty)
    }

    @Test
    func testDescriptionListsAllAndImportant() {
        #expect(Mailbox.Info.Attributes([.all]).description == "[\\All]")
        #expect(Mailbox.Info.Attributes([.important, .hasNoChildren]).description == "[hasNoChildren, \\Important]")
    }

    @Test
    func testLocalizedAllMailIsFoundByAttribute() {
        let allMail = Mailbox.Info(name: "[Google Mail]/Alle Nachrichten", attributes: [.all, .hasNoChildren],
                                   hierarchyDelimiter: "/")
        let important = Mailbox.Info(name: "[Google Mail]/Wichtig", attributes: [.important],
                                     hierarchyDelimiter: "/")
        let mailboxes = [Mailbox.Info(name: "INBOX", attributes: [.inbox], hierarchyDelimiter: "/"),
                         important, allMail]

        #expect(mailboxes.allMail?.name == allMail.name)
        #expect(mailboxes.archive?.name == allMail.name, "archiving on Gmail means moving to All Mail")
        #expect(mailboxes.specialFolders.map(\.name).contains(allMail.name))
        #expect(mailboxes.specialFolders.map(\.name).contains(important.name))
    }

    @Test
    func testArchiveAttributeWinsOverAll() {
        let archive = Mailbox.Info(name: "Archive", attributes: [.archive], hierarchyDelimiter: "/")
        let all = Mailbox.Info(name: "All", attributes: [.all], hierarchyDelimiter: "/")
        #expect([all, archive].archive?.name == "Archive")
    }

    @Test
    func testArchiveNameWinsOverAll() {
        let archive = Mailbox.Info(name: "Archive", attributes: [], hierarchyDelimiter: "/")
        let all = Mailbox.Info(name: "Alle Nachrichten", attributes: [.all], hierarchyDelimiter: "/")
        #expect([all, archive].archive?.name == "Archive")
        #expect([all].archive?.name == "Alle Nachrichten")
    }
}
