// AddressParserMalformedInputTests.swift
// Malformed address text is never guessed at and never dropped: a malformed element that
// no recovery rule reads comes back as invalid text, and the well-formed elements around
// it are read as usual.
//
// Many of these cases come from the review of #240, where a parser that repaired or
// silently shortened malformed lists handed consumers a different address than the
// header named.

import Testing
@testable import SwiftMail

private func mailbox(_ address: String, _ name: String? = nil) -> AddressListEntry {
    .mailbox(EmailAddress(name: name, address: address))
}

@Suite("Address parser: malformed input", .timeLimit(.minutes(1)))
struct AddressParserMalformedInputTests {

    @Test("Text that no rule of the grammar matches is kept whole", arguments: [
        // CFWS where the grammar has none: removing it would name a different mailbox
        "first last@example.com",
        #""a" "b"@example.com"#,
        "Alice <first(comment)last@example.com>",
        // Text after an address instead of a comma
        "bob@example.com junk",
        "Alice <alice@example.com> bob@example.com",
        "Alice <alice@example.com> x",
        "alice@example.com Bob <bob@example.com>",
        // A colon or semicolon outside a group
        "alice@example.com: bob@example.com",
        "a@example.com; b@example.com",
        "Team: a@example.com; b@example.com",
        // Groups that nest, or hold a member that isn't a mailbox
        "Team: a@example.com, Other: b@example.com;",
        "Team: junk",
        // Constructs left open swallow the rest of the field
        "alice@example.com (unterminated, bob@example.com",
        "\"unterminated, bob@example.com",
        "a@[unterminated, b@example.com",
        "Ann <ann@example.com, bob@example.com",
        "(unterminated comment",
        "John <john@example.com",
        // Not addr-specs
        "<>",
        ".@example.com",
        "a@example..com",
        "a@example.com.",
        "@example.com",
        "a@",
        "user@[a[b]",
        "<@relay.example john@example.com>",
        "<:john@example.com>",
        "Alice <alice@example.com>>",
        // A display name holding another address: a missing comma, never a name
        "alice@example.com <bob@example.com>",
        "x > y <a@example.com>"
    ])
    func malformedElementIsKept(_ text: String) {
        #expect(AddressParser.parseAddressList(text) == [.invalid(text)])
    }

    @Test("Control characters make an element invalid, wherever they are", arguments: [
        "a\u{0001}b@example.com",
        "a\u{000B}b@example.com",
        "\"a\u{0000}b\"@example.com",
        "a@example.com (\u{007F})",
        "a\u{0085}b@example.com",
        "a@[1.2.3.4\u{001B}]"
    ])
    func controlCharacters(_ text: String) {
        #expect(AddressParser.parseAddressList(text) == [.invalid(text)])
    }

    @Test("A line break that doesn't fold is not white space")
    func unfoldedLineBreak() {
        let text = "a@example.com\r\nBcc: evil@example.com"
        #expect(AddressParser.parseAddressList(text) == [.invalid(text)])
        #expect(AddressParser.parseAddressList("a@example.com\r, b@example.com")
            == [.invalid("a@example.com\r"), mailbox("b@example.com")])
    }

    @Test("Well-formed elements around a malformed one are read as usual", arguments: [
        ("a@example.com, b\u{0007}@example.com", [mailbox("a@example.com"), .invalid("b\u{0007}@example.com")]),
        ("a@example.com, <>, b@example.com", [mailbox("a@example.com"), .invalid("<>"), mailbox("b@example.com")]),
        ("Doe, Jane <jane@example.com>, John <john@example.com>",
         [.invalid("Doe"), mailbox("jane@example.com", "Jane"), mailbox("john@example.com", "John")]),
        ("x@example.com, first last@example.com , y@example.com",
         [mailbox("x@example.com"), .invalid("first last@example.com"), mailbox("y@example.com")]),
        ("Team: a@example.com, junk;, b@example.com",
         [.invalid("Team: a@example.com, junk;"), mailbox("b@example.com")]),
        ("a@example.com, (unterminated", [mailbox("a@example.com"), .invalid("(unterminated")]),
        ("\"Doe, Jane\" <jane@example.com>, Doe, John <john@example.com>",
         [mailbox("jane@example.com", "Doe, Jane"), .invalid("Doe"), mailbox("john@example.com", "John")])
    ] as [(String, [AddressListEntry])])
    func neighboursSurvive(_ text: String, _ expected: [AddressListEntry]) {
        #expect(AddressParser.parseAddressList(text) == expected)
    }

    @Test("Invalid text is unfolded and trimmed")
    func invalidTextIsUnfolded() {
        #expect(AddressParser.parseAddressList("  first\r\n last@example.com  ")
            == [.invalid("first last@example.com")])
    }

    @Test("A malformed group is invalid as a whole rather than losing members silently")
    func malformedGroup() {
        let entries = AddressParser.parseAddressList("Team: a@example.com, b\u{0001}@example.com;")
        #expect(entries == [.invalid("Team: a@example.com, b\u{0001}@example.com;")])
        #expect(entries.mailboxes.isEmpty)
    }

    @Test("EmailAddress(_:) rejects malformed text")
    func singleMailboxRejectsMalformedText() {
        #expect(EmailAddress("first last@example.com") == nil)
        #expect(EmailAddress("a\u{0001}b@example.com") == nil)
        #expect(EmailAddress("Alice <alice@example.com") == nil)
        #expect(EmailAddress("alice@example.com Bob <bob@example.com>") == nil)
    }

    @Test("An invalid entry round-trips through its own text")
    func invalidEntryRoundTrip() {
        for text in ["junk", "Doe", "a@example.com; b@example.com", "\"unterminated, b@example.com"] {
            let entry = AddressListEntry(text)
            #expect(entry == .invalid(text))
            #expect(entry.flatMap { AddressListEntry($0.description) } == entry)
        }
    }

    @Test("Invalid text with a control character is written as encoded-words, which read back as that text")
    func invalidTextWithControlIsEncoded() {
        let texts = [
            "a@example.com\r\nBcc: evil@example.com\u{000B}x",
            "a\u{0000}@example.com",
            "\u{0007}bob@example.com",
            "victim@example.com\r",
            "Jane\r@Doe"
        ]
        for text in texts {
            let description = AddressListEntry.invalid(text).description
            #expect(description.hasPrefix("=?UTF-8?B?"), "\(description.debugDescription)")
            #expect(AddressRoundTripTests.isHeaderSafe(description), "\(description.debugDescription)")
            #expect(AddressListEntry(description) == .invalid(text), "\(text.debugDescription) didn't read back")
        }
    }

    @Test("Invalid text is written as it is only when it reads back as itself")
    func invalidTextWithoutControlIsVerbatim() {
        #expect(AddressListEntry.invalid("Jörg [Vertrieb").description == "Jörg [Vertrieb")
        // Written as it is, this would read back as a mailbox (see the recovery rules).
        let addressLike = AddressListEntry.invalid("Jörg [Vertrieb <joerg@example.com>")
        #expect(addressLike.description.hasPrefix("=?UTF-8?B?"))
        #expect(AddressListEntry(addressLike.description) == addressLike)
    }

    @Test("An element that is only a quoted-string, or only encoded-words, is invalid text of what it stands for")
    func phraseOnlyElements() {
        #expect(AddressParser.parseAddressList("\"Doe, John\", jane@example.com")
            == [.invalid("Doe, John"), mailbox("jane@example.com")])
        #expect(AddressParser.parseAddressList("\"victim@example.com\"") == [.invalid("victim@example.com")])
        #expect(AddressParser.parseAddressList("=?UTF-8?Q?Doe=2C_John?=") == [.invalid("Doe, John")])
        #expect(AddressParser.parseAddressList("=?UTF-8?Q?Doe=2C?=\r\n =?UTF-8?Q?_John?=") == [.invalid("Doe, John")])
        #expect(AddressParser.parseAddressList("\"\", a@example.com") == [.invalid(""), mailbox("a@example.com")])
        // Anything more is kept as written: a comment, or a word that isn't encoded.
        #expect(AddressParser.parseAddressList("\"Doe\" (the one)") == [.invalid("\"Doe\" (the one)")])
        #expect(AddressParser.parseAddressList("=?UTF-8?Q?Doe?= John") == [.invalid("=?UTF-8?Q?Doe?= John")])
    }
}
