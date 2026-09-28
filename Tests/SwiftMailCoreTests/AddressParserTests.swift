// AddressParserTests.swift
// Well-formed address text: the RFC 5322 grammar, its obsolete forms, RFC 6532 UTF-8
// and RFC 2047 display names, each read into the structure it stands for.

import Testing
@testable import SwiftMail

private func mailbox(_ address: String, _ name: String? = nil) -> AddressListEntry {
    .mailbox(EmailAddress(name: name, address: address))
}

private func member(_ address: String, _ name: String? = nil) -> EmailAddress {
    EmailAddress(name: name, address: address)
}

@Suite("Address parser: well-formed input", .timeLimit(.minutes(1)))
struct AddressParserTests {

    // MARK: - RFC 5322 Appendix A

    @Test("RFC 5322 Appendix A examples", arguments: [
        // A.1.1
        ("John Doe <jdoe@machine.example>", [mailbox("jdoe@machine.example", "John Doe")]),
        // A.1.2
        (#""Joe Q. Public" <john.q.public@example.com>"#,
         [mailbox("john.q.public@example.com", "Joe Q. Public")]),
        ("Mary Smith <mary@x.test>, jdoe@example.org, Who? <one@y.test>",
         [mailbox("mary@x.test", "Mary Smith"), mailbox("jdoe@example.org"), mailbox("one@y.test", "Who?")]),
        (#"<boss@nil.test>, "Giant; \"Big\" Box" <sysservices@example.net>"#,
         [mailbox("boss@nil.test"), mailbox("sysservices@example.net", #"Giant; "Big" Box"#)]),
        // A.1.3
        ("A Group:Ed Jones <c@a.test>,joe@where.test,John <jdoe@one.test>;",
         [.group(name: "A Group", members: [
            member("c@a.test", "Ed Jones"), member("joe@where.test"), member("jdoe@one.test", "John")
         ])]),
        ("Undisclosed recipients:;", [.group(name: "Undisclosed recipients", members: [])]),
        // A.5
        (#"Pete(A nice \) chap) <pete(his account)@silly.test(his host)>"#, [mailbox("pete@silly.test", "Pete")]),
        ("A Group(Some people)\r\n     :Chris Jones <c@(Chris's host.)public.example>,\r\n"
            + "         joe@example.org,\r\n  John <jdoe@one.test> (my dear friend); (the end of the group)",
         [.group(name: "A Group", members: [
            member("c@public.example", "Chris Jones"), member("joe@example.org"), member("jdoe@one.test", "John")
         ])]),
        ("(Empty list)(start)Hidden recipients  :(nobody(that I know))  ;",
         [.group(name: "Hidden recipients", members: [])]),
        // A.6.1
        ("Joe Q. Public <john.q.public@example.com>", [mailbox("john.q.public@example.com", "Joe Q. Public")]),
        ("Mary Smith <@node.test:mary@example.net>, , jdoe@test  . example",
         [mailbox("mary@example.net", "Mary Smith"), mailbox("jdoe@test.example")]),
        // A.6.3
        ("John Doe <jdoe@machine(comment).  example>", [mailbox("jdoe@machine.example", "John Doe")]),
        ("Mary Smith\r\n  \r\n          <mary@example.net>", [mailbox("mary@example.net", "Mary Smith")])
    ] as [(String, [AddressListEntry])])
    func rfc5322AppendixA(_ text: String, _ expected: [AddressListEntry]) {
        #expect(AddressParser.parseAddressList(text) == expected)
    }

    // MARK: - addr-spec

    @Test("An addr-spec comes back in canonical form", arguments: [
        ("a@example.com", "a@example.com"),
        ("  <a@example.com>  ", "a@example.com"),
        (#""john doe"@example.com"#, #""john doe"@example.com"#),
        (#""john"@example.com"#, "john@example.com"),
        (#""john.doe"@example.com"#, "john.doe@example.com"),
        (#"".john"@example.com"#, #"".john"@example.com"#),
        (#"""@example.com"#, #"""@example.com"#),
        ("\"first\tlast\"@example.com", "\"first\tlast\"@example.com"),
        ("\"first\r\n last\"@example.com", #""first last"@example.com"#),
        (#""a\"b"@example.com"#, #""a\"b"@example.com"#),
        (#""a\\b"@example.com"#, #""a\\b"@example.com"#),
        (#""a\b"@example.com"#, "ab@example.com"),
        (#""john:doe"@example.com"#, #""john:doe"@example.com"#),
        ("john . doe @ example . com", "john.doe@example.com"),
        (#""john".doe@example.com"#, "john.doe@example.com"),
        (#""john doe".smith@example.com"#, #""john doe.smith"@example.com"#),
        ("bob(comment)@example.com", "bob@example.com"),
        ("Alice <(c)alice@example.com(c)>", "alice@example.com"),
        ("user+tag@sub.example.com", "user+tag@sub.example.com"),
        ("!#$%&'*+-/=?^_`{|}~@example.com", "!#$%&'*+-/=?^_`{|}~@example.com"),
        ("A@EXAMPLE.COM", "A@EXAMPLE.COM")
    ])
    func canonicalAddrSpec(_ text: String, _ address: String) {
        #expect(AddressParser.parseAddressList(text).mailboxes.map(\.address) == [address])
    }

    @Test("Domain literals keep their content, white space included", arguments: [
        ("a@[192.168.0.1]", "a@[192.168.0.1]"),
        ("a@[IPv6:2001:db8::1]", "a@[IPv6:2001:db8::1]"),
        ("user@[tag value]", "user@[tag value]"),
        ("user@[tag<value]", "user@[tag<value]"),
        ("Ops <ops@[tag:v <x>]>", "ops@[tag:v <x>]"),
        (#"Ann <user@[a"b]>"#, #"user@[a"b]"#),
        (#"user@[a\]b]"#, #"user@[a\]b]"#),
        ("user@ [1.2.3.4] (host)", "user@[1.2.3.4]")
    ])
    func domainLiterals(_ text: String, _ address: String) {
        #expect(AddressParser.parseAddressList(text).mailboxes.map(\.address) == [address])
    }

    @Test("A domain literal's colons, commas and quotes are not address syntax")
    func domainLiteralDelimiters() {
        #expect(AddressParser.parseAddressList(#"user@[a"b], bob@example.com"#)
            == [mailbox(#"user@[a"b]"#), mailbox("bob@example.com")])
        #expect(AddressParser.parseAddressList("user@[a,b;c], bob@example.com")
            == [mailbox("user@[a,b;c]"), mailbox("bob@example.com")])
    }

    @Test("Obsolete source routes are dropped", arguments: [
        ("<@relay.example:john@example.com>", "john@example.com"),
        ("<@a.example,@b.example:x@example.com>", "x@example.com"),
        ("<,@a.example, ,@b.example:x@example.com>", "x@example.com"),
        (#"<@relay.example:"john:doe"@example.com>"#, #""john:doe"@example.com"#),
        ("<@[10.0.0.1]:x@example.com>", "x@example.com")
    ])
    func obsoleteRoutes(_ text: String, _ address: String) {
        #expect(AddressParser.parseAddressList(text).mailboxes.map(\.address) == [address])
    }

    // MARK: - RFC 6532

    @Test("UTF-8 is text wherever RFC 6532 allows it, and only SP and HTAB are white space")
    func internationalizedAddresses() {
        #expect(AddressParser.parseAddressList("用户@例子.广告") == [mailbox("用户@例子.广告")])
        #expect(AddressParser.parseAddressList("Zoë <zoë@example.com>") == [mailbox("zoë@example.com", "Zoë")])
        #expect(AddressParser.parseAddressList("first\u{00A0}last@example.com")
            == [mailbox("first\u{00A0}last@example.com")])
        #expect(AddressParser.parseAddressList("\u{00A0}first@example.com") == [mailbox("\u{00A0}first@example.com")])
        #expect(AddressParser.parseAddressList("Ann\u{2003}Lee <ann@example.com>")
            == [mailbox("ann@example.com", "Ann\u{2003}Lee")])
    }

    @Test("An ASCII delimiter joined to a combining mark in one Character is still a delimiter")
    func delimiterBeforeCombiningMark() {
        #expect(AddressParser.parseAddressList("\"\u{0301}Doe, Jane\" <jane@example.com>, bob@example.com")
            == [mailbox("jane@example.com", "\u{0301}Doe, Jane"), mailbox("bob@example.com")])
        #expect(AddressParser.parseAddressList("a@example.com,\r\n \u{0301}Bob <bob@example.com>")
            == [mailbox("a@example.com"), mailbox("bob@example.com", "\u{0301}Bob")])
    }

    // MARK: - Display names

    @Test("A phrase reads as the text it stands for", arguments: [
        (#""John" Doe <j@example.com>"#, "John Doe"),
        (#""John"Doe <j@example.com>"#, "JohnDoe"),
        ("John(comment)Doe <j@example.com>", "John Doe"),
        ("John   Doe <j@example.com>", "John Doe"),
        ("John\r\n Doe <j@example.com>", "John Doe"),
        (#""John \"Ace\"" Doe <j@example.com>, bob@example.com"#, #"John "Ace" Doe"#),
        (#""  padded  " <j@example.com>"#, "  padded  "),
        ("\"tab\there\" <j@example.com>", "tab\there"),
        (#""Team\\Ops" <j@example.com>"#, #"Team\Ops"#),
        ("John Q. Public <j@example.com>", "John Q. Public"),
        ("Dr. . Who <j@example.com>", "Dr. . Who"),
        ("Who? <j@example.com>", "Who?")
    ])
    func phraseText(_ text: String, _ name: String) {
        #expect(AddressParser.parseAddressList(text).mailboxes.first?.name == name)
    }

    @Test("A fold between a backslash and the character it quotes is unfolded first (RFC 5322 §2.2.3)")
    func foldInsideQuotedPair() {
        #expect(AddressParser.parseAddressList("\"a\\\r\n b\"@example.com") == [mailbox(#""a b"@example.com"#)])
        #expect(AddressParser.parseAddressList("a@example.com (a\\\r\n b)") == [mailbox("a@example.com", "a b")])
        #expect(AddressParser.parseAddressList("\"Jo\\\r\n hn\" <j@example.com>")
            == [mailbox("j@example.com", "Jo hn")])
        #expect(AddressParser.parseAddressList("a@[1\\\r\n 2]") == [mailbox("a@[1\\ 2]")])
    }

    @Test("An empty display name is no display name")
    func emptyDisplayName() {
        #expect(AddressParser.parseAddressList(#""" <a@example.com>"#) == [mailbox("a@example.com")])
        #expect(AddressParser.parseAddressList(#""" <a@example.com>"#).mailboxes.first?.name == nil)
    }

    // MARK: - RFC 2047

    @Test("Encoded-words are decoded where RFC 2047 allows them", arguments: [
        ("=?UTF-8?Q?J=C3=B6rg?= <j@example.com>", "Jörg"),
        ("=?ISO-8859-1?Q?Andr=E9?= Pirard <PIRARD@vm1.ulg.ac.be>", "André Pirard"),
        ("=?US-ASCII?Q?Keith_Moore?= <moore@cs.utk.edu>", "Keith Moore"),
        ("=?US-ASCII*EN?Q?Keith_Moore?= <moore@cs.utk.edu>", "Keith Moore"),
        ("=?ISO-8859-1?Q?Keld_J=F8rn_Simonsen?= <keld@dkuug.dk>", "Keld Jørn Simonsen"),
        ("=?ISO-8859-1?Q?Olle_J=E4rnefors?= <ojarnef@admin.kth.se>", "Olle Järnefors"),
        ("=?utf-8?b?w4Q=?= <a@example.com>", "Ä"),
        // RFC 2047 §8: white space between adjacent encoded-words is not displayed
        ("=?ISO-8859-1?Q?a?= <x@example.com>", "a"),
        ("=?ISO-8859-1?Q?a?= b <x@example.com>", "a b"),
        ("=?ISO-8859-1?Q?a?= =?ISO-8859-1?Q?b?= <x@example.com>", "ab"),
        ("=?ISO-8859-1?Q?a?=  =?ISO-8859-1?Q?b?= <x@example.com>", "ab"),
        ("=?ISO-8859-1?Q?a?=\r\n    =?ISO-8859-1?Q?b?= <x@example.com>", "ab"),
        ("=?ISO-8859-1?Q?a_b?= <x@example.com>", "a b"),
        ("=?ISO-8859-1?Q?a?= =?ISO-8859-2?Q?_b?= <x@example.com>", "a b"),
        // A character whose bytes are split across two encoded-words survives
        ("=?UTF-8?Q?=C3?= =?UTF-8?Q?=A9?= <a@example.com>", "é"),
        // A comment between encoded-words reads as a space
        ("=?UTF-8?Q?John?= (team) =?UTF-8?Q?Doe?= <john@example.com>", "John Doe"),
        // Next to the angle bracket is the edge of the phrase
        ("=?UTF-8?Q?John?=<john@example.com>", "John"),
        ("Team =?UTF-8?Q?M=C3=BCller?= <t@example.com>", "Team Müller")
    ])
    func decodedEncodedWords(_ text: String, _ name: String) {
        #expect(AddressParser.parseAddressList(text).mailboxes.first?.name == name)
    }

    @Test("Encoded-word look-alikes stay literal", arguments: [
        // Inside a quoted-string (RFC 2047 §5)
        (#""=?UTF-8?Q?John?=" <john@example.com>"#, "=?UTF-8?Q?John?="),
        // Not a whole word
        (#"abc=?UTF-8?Q?def?= "John" <john@example.com>"#, "abc=?UTF-8?Q?def?= John"),
        ("pre=?UTF-8?B?SGVsbG8=?=post <bob@example.com>", "pre=?UTF-8?B?SGVsbG8=?=post"),
        // Next to another word, with no white space between
        (#"=?UTF-8?Q?John?="Doe" <john@example.com>"#, "=?UTF-8?Q?John?=Doe"),
        (#""Ann"=?UTF-8?Q?Lee?= <ann@example.com>"#, "Ann=?UTF-8?Q?Lee?="),
        ("=?UTF-8?Q?Dr?=. Who <who@example.com>", "=?UTF-8?Q?Dr?=. Who"),
        // Not encoded-word syntax: no charset, no encoded text, or no such encoding
        ("=?UTF-8?X?John?= <john@example.com>", "=?UTF-8?X?John?="),
        ("=??Q?John?= <john@example.com>", "=??Q?John?="),
        ("=?*en?Q?b?= <x@example.com>", "=?*en?Q?b?="),
        ("John =?UTF-8?Q??= Doe <x@example.com>", "John =?UTF-8?Q??= Doe"),
        // A word that doesn't decode stays exactly as written
        ("=?X-UNKNOWN*en?Q?=ZZ?= <x@example.com>", "=?X-UNKNOWN*en?Q?=ZZ?=")
    ])
    func literalEncodedWordLookalikes(_ text: String, _ name: String) {
        #expect(AddressParser.parseAddressList(text).mailboxes.first?.name == name)
    }

    // MARK: - Legacy comment names

    @Test("A bare address takes its first trailing comment as the display name", arguments: [
        ("bob@example.com (Bob)", "Bob" as String?),
        ("bob@example.com (Bob Smith) (work)", "Bob Smith"),
        ("bob@example.com () (Bob)", "Bob"),
        ("bob@example.com (  Bob   Smith  )", "Bob Smith"),
        ("bob@example.com (Bob (the builder))", "Bob (the builder)"),
        (#"bob@example.com (Bob \) Smith)"#, "Bob ) Smith"),
        ("a@example.com (=?UTF-8?Q?J=C3=B6rg?=)", "Jörg"),
        ("a@example.com (=?UTF-8?Q?J=C3=B6rg?= Smith)", "Jörg Smith"),
        ("a@example.com ((=?UTF-8?Q?J=C3=B6rg?=))", "(Jörg)"),
        ("a@example.com (=?UTF-8?Q?a?=  =?UTF-8?Q?b?= c)", "ab c"),
        (#"a@example.com (\=?UTF-8?Q?J=C3=B6rg?=)"#, "=?UTF-8?Q?J=C3=B6rg?="),
        ("bob@example.com ()", nil),
        ("bob(Bob)@example.com", nil),
        ("Alice <alice@example.com> (work)", "Alice"),
        ("<alice@example.com> (work)", nil)
    ])
    func legacyCommentNames(_ text: String, _ name: String?) {
        let mailboxes = AddressParser.parseAddressList(text).mailboxes
        #expect(mailboxes.count == 1)
        #expect(mailboxes.first?.name == name)
    }

    // MARK: - Lists and groups

    @Test("Empty list elements are skipped", arguments: [
        (",, a@example.com,,b@example.com,", [mailbox("a@example.com"), mailbox("b@example.com")]),
        ("(comment only), a@example.com", [mailbox("a@example.com")]),
        ("a@example.com, (trailing comment)", [mailbox("a@example.com")]),
        ("", []),
        (" \t ", []),
        (",", [])
    ] as [(String, [AddressListEntry])])
    func emptyElements(_ text: String, _ expected: [AddressListEntry]) {
        #expect(AddressParser.parseAddressList(text) == expected)
    }

    @Test("Groups keep their name and members", arguments: [
        ("Friends: Alice <alice@example.com>, Bob <bob@example.com>;",
         [.group(name: "Friends", members: [member("alice@example.com", "Alice"), member("bob@example.com", "Bob")])]),
        (#""Staff@example.com": Alice <alice@example.com>;"#,
         [.group(name: "Staff@example.com", members: [member("alice@example.com", "Alice")])]),
        ("Team: a@example.com;, b@example.com (x)",
         [.group(name: "Team", members: [member("a@example.com")]), mailbox("b@example.com", "x")]),
        ("Team:,,a@example.com, ,;", [.group(name: "Team", members: [member("a@example.com")])]),
        ("undisclosed-recipients:;", [.group(name: "undisclosed-recipients", members: [])]),
        ("=?UTF-8?Q?Gr=C3=BCppe?=: a@example.com;", [.group(name: "Grüppe", members: [member("a@example.com")])]),
        ("Team: <@relay.example:a@example.com>, \"Doe, Jane\" <jane@example.com>;",
         [.group(name: "Team", members: [member("a@example.com"), member("jane@example.com", "Doe, Jane")])]),
        ("a@example.com, Team: b@example.com;, c@example.com",
         [mailbox("a@example.com"), .group(name: "Team", members: [member("b@example.com")]), mailbox("c@example.com")])
    ] as [(String, [AddressListEntry])])
    func groups(_ text: String, _ expected: [AddressListEntry]) {
        #expect(AddressParser.parseAddressList(text) == expected)
    }

    @Test("mailboxes flattens groups and skips invalid text")
    func flattenedMailboxes() {
        let entries = AddressParser.parseAddressList("a@example.com, Team: b@example.com, c@example.com;, junk")
        #expect(entries.mailboxes.map(\.address) == ["a@example.com", "b@example.com", "c@example.com"])
    }

    // MARK: - EmailAddress(_:)

    @Test("EmailAddress(_:) reads exactly one mailbox")
    func singleMailbox() {
        #expect(EmailAddress("Jane Doe <jane@example.com>") == member("jane@example.com", "Jane Doe"))
        #expect(EmailAddress("<test@example.com>") == member("test@example.com"))
        #expect(EmailAddress("  user@example.com  ") == member("user@example.com"))
        #expect(EmailAddress("Alice <alice@example.com> (outer (nested))") == member("alice@example.com", "Alice"))
        #expect(EmailAddress("Alice <alice@example.com> (work > remote)") == member("alice@example.com", "Alice"))
        #expect(EmailAddress("a@example.com, b@example.com") == nil)
        #expect(EmailAddress("Team: a@example.com;") == nil)
        #expect(EmailAddress("a@example.com,") == nil)
        #expect(EmailAddress("") == nil)
        #expect(EmailAddress("Alice <alice@example.com> arbitrary") == nil)
    }
}
