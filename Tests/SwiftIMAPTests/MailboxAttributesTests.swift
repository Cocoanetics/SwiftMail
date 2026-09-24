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
}
