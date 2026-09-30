// AddressParserRecoveryTests.swift
// Malformations common in real mail that are read anyway, because the addresses they name
// are unambiguous: each rule returns exactly the addresses written, and never splits,
// merges or alters one.

import Testing
@testable import SwiftMail

private func mailbox(_ address: String, _ name: String? = nil) -> AddressListEntry {
    .mailbox(EmailAddress(name: name, address: address))
}

private func member(_ address: String, _ name: String? = nil) -> EmailAddress {
    EmailAddress(name: name, address: address)
}

@Suite("Address parser: recovered malformations", .timeLimit(.minutes(1)))
struct AddressParserRecoveryTests {

    @Test("A display name that breaks the phrase grammar is read in front of a well-formed address", arguments: [
        ("John [Sales] <john@example.com>", "John [Sales]"),
        ("Jörg [Vertrieb] <joerg@example.com>", "Jörg [Vertrieb]"),
        ("Café\u{0092} Owner <owner@example.com>", "Café\u{0092} Owner"),
        ("A\u{0001}B <ab@example.com>", "A\u{0001}B"),
        ("\"Caf\u{0092}\" Owner <owner@example.com>", "Caf\u{0092} Owner"),
        ("Dr. Who; Esq. <who@example.com>", "Dr. Who; Esq."),
        ("=?UTF-8?Q?J=C3=B6rg?= [Vertrieb] (sales) <joerg@example.com>", "Jörg [Vertrieb]"),
        ("Support: [Sales] <s@example.com>", "Support: [Sales]"),
        ("Jörg [Vertrieb <joerg@example.com>", "Jörg [Vertrieb")
    ])
    func lenientDisplayName(_ text: String, _ name: String) {
        let entries = AddressParser.parseAddressList(text)
        #expect(entries.count == 1)
        #expect(entries.mailboxes.first?.name == name)
    }

    @Test("A display name that repeats its own address is a name, not a second address")
    func addressAsDisplayName() {
        #expect(AddressParser.parseAddressList("john@example.com <john@example.com>")
            == [mailbox("john@example.com", "john@example.com")])
        #expect(AddressParser.parseAddressList("John@Example.COM <john@example.com>")
            == [mailbox("john@example.com", "John@Example.COM")])
        // A different address there is a missing comma, and stays invalid text.
        #expect(AddressParser.parseAddressList("alice@example.com <bob@example.com>")
            == [.invalid("alice@example.com <bob@example.com>")])
        #expect(AddressParser.parseAddressList("alice@example.com Bob <bob@example.com>")
            == [.invalid("alice@example.com Bob <bob@example.com>")])
    }

    @Test("Recovered and well-formed elements sit side by side")
    func recoveredNeighbours() {
        #expect(AddressParser.parseAddressList("Jörg [Vertrieb] <joerg@example.com>, bob@example.com")
            == [mailbox("joerg@example.com", "Jörg [Vertrieb]"), mailbox("bob@example.com")])
    }

    @Test("A group running to the end of the field without its ';' reads as a group", arguments: [
        ("Team: a@example.com", [AddressListEntry.group(name: "Team", members: [member("a@example.com")])]),
        ("Team:", [.group(name: "Team", members: [])]),
        ("Support: Sales <s@example.com>, bob@example.com",
         [.group(name: "Support", members: [member("s@example.com", "Sales"), member("bob@example.com")])]),
        ("a@example.com, Zoë: Sales <zoe@example.com>, bob@example.com",
         [mailbox("a@example.com"),
          .group(name: "Zoë", members: [member("zoe@example.com", "Sales"), member("bob@example.com")])])
    ])
    func unterminatedGroupAtEnd(_ text: String, _ expected: [AddressListEntry]) {
        #expect(AddressParser.parseAddressList(text) == expected)
    }

    @Test("A local-part with a leading, trailing or doubled dot keeps its text, quoted", arguments: [
        ("taro.@docomo.ne.jp", #""taro."@docomo.ne.jp"#),
        ("taro..yamada@docomo.ne.jp", #""taro..yamada"@docomo.ne.jp"#),
        (".taro@docomo.ne.jp", #"".taro"@docomo.ne.jp"#),
        ("Taro <taro.@docomo.ne.jp>", #""taro."@docomo.ne.jp"#),
        (#""taro."@docomo.ne.jp"#, #""taro."@docomo.ne.jp"#),
        ("taro . . yamada @ docomo.ne.jp", #""taro..yamada"@docomo.ne.jp"#)
    ])
    func extraDotsInLocalPart(_ text: String, _ address: String) {
        let mailboxes = AddressParser.parseAddressList(text).mailboxes
        #expect(mailboxes.map(\.address) == [address])
        #expect(mailboxes.first.flatMap { EmailAddress($0.description) } == mailboxes.first)
    }

    @Test("A single mailbox may hold an unquoted comma in its display name")
    func singleMailboxWithComma() {
        #expect(EmailAddress("Doe, John <john@example.com>") == member("john@example.com", "Doe, John"))
        #expect(EmailAddress("Company, Inc. <billing@example.com>") == member("billing@example.com", "Company, Inc."))
        #expect(EmailAddress("john@example.com <john@example.com>") == member("john@example.com", "john@example.com"))
        // A list is still not one mailbox.
        #expect(EmailAddress("a@example.com, Bob <b@example.com>") == nil)
        #expect(EmailAddress("Alice <a@example.com>, Bob <b@example.com>") == nil)
        // In an address list the comma separates elements, and elements are never
        // merged: the invalid text stays visible rather than joining a name.
        #expect(AddressParser.parseAddressList("Doe, John <john@example.com>")
            == [.invalid("Doe"), mailbox("john@example.com", "John")])
        #expect(AddressParser.parseAddressList("Doe, John <john@example.com>, bob@example.com")
            == [.invalid("Doe"), mailbox("john@example.com", "John"), mailbox("bob@example.com")])
        #expect(AddressParser.parseAddressList("Team:;, Bob <bob@example.com>")
            == [.group(name: "Team", members: []), mailbox("bob@example.com", "Bob")])
        #expect(AddressParser.parseAddressList("Team:;, Doe, John <john@example.com>")
            == [.group(name: "Team", members: []), .invalid("Doe"), mailbox("john@example.com", "John")])
        #expect(AddressParser.parseAddressList("a@example.com, Doe, John <john@example.com>")
            == [mailbox("a@example.com"), .invalid("Doe"), mailbox("john@example.com", "John")])
    }

    @Test("A recovered mailbox reads back from its own string form")
    func recoveredMailboxRoundTrip() {
        let texts = [
            "John [Sales] <john@example.com>", "Café\u{0092} Owner <owner@example.com>",
            "john@example.com <john@example.com>", "Taro <taro.@docomo.ne.jp>"
        ]
        for text in texts {
            guard let address = EmailAddress(text) else {
                Issue.record("not recovered: \(text.debugDescription)")
                continue
            }
            #expect(EmailAddress(address.description) == address, "\(text.debugDescription)")
            #expect(AddressParser.parseMailbox(address.displayString) == address, "\(text.debugDescription)")
        }
    }
}
