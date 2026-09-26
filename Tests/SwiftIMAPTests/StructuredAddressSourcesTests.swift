import Foundation
import NIO
import NIOEmbedded
import Testing
@testable import SwiftMail

/// Structured addresses from sources other than a well-ordered ENVELOPE: header
/// literals (in any FETCH order, with RFC 5322 groups), EML files, and `Email`.
extension FetchMessageInfoHandlerTests {
    // MARK: - Structured Addresses Beyond ENVELOPE

    @Test
    func testHeaderAddressesSurviveANilEnvelopeThatArrivesLater() async throws {
        let headerBlock = "To: Jane <jane@example.com>\r\n\r\n"
        let response = "* 1 FETCH (BODY[HEADER.FIELDS (TO)] {\(headerBlock.utf8.count)}\r\n"
            + headerBlock + " ENVELOPE (NIL NIL NIL NIL NIL NIL NIL NIL NIL NIL))\r\n"

        let infos = try await executeFetch([response, "A001 OK FETCH completed\r\n"])

        try #require(infos.count == 1)
        #expect(infos[0].to == ["Jane <jane@example.com>"])
        #expect(infos[0].toAddresses == [EmailAddress(name: "Jane", address: "jane@example.com")])
    }

    @Test
    func testHeaderGroupAddressesAreFlattenedToMembers() async throws {
        let headerBlock = "From: Carol <carol@example.com>, Dan <dan@example.com>\r\n"
            + "To: Friends: Alice <alice@example.com>, \"Doe, Bob\" <bob@example.com>;, eve@example.com\r\n"
            + "Cc: Undisclosed recipients:;\r\n\r\n"
        let response = "* 1 FETCH (BODY[HEADER.FIELDS (FROM TO CC)] {\(headerBlock.utf8.count)}\r\n"
            + headerBlock + ")\r\n"

        let infos = try await executeFetch([response, "A001 OK FETCH completed\r\n"])

        try #require(infos.count == 1)
        #expect(infos[0].fromAddress == EmailAddress(name: "Carol", address: "carol@example.com"))
        #expect(infos[0].toAddresses == [
            EmailAddress(name: "Alice", address: "alice@example.com"),
            EmailAddress(name: "Doe, Bob", address: "bob@example.com"),
            EmailAddress(address: "eve@example.com")
        ])
        #expect(infos[0].ccAddresses.isEmpty)
    }

    @Test
    func testEMLParserFillsStructuredAddresses() throws {
        let eml = "From: Alice <alice@example.com>\r\n"
            + "To: Team: Bob <bob@example.com>;\r\n"
            + "Cc: carol@example.com\r\n"
            + "Subject: Hello\r\n\r\nBody\r\n"

        let message = try Message(emlData: Data(eml.utf8))

        #expect(message.header.fromAddress == EmailAddress(name: "Alice", address: "alice@example.com"))
        #expect(message.header.toAddresses == [EmailAddress(name: "Bob", address: "bob@example.com")])
        #expect(message.header.ccAddresses == [EmailAddress(address: "carol@example.com")])
    }

    @Test
    func testMessageFromEmailKeepsStructuredAddresses() {
        let sender = EmailAddress(name: "Doe, Jane", address: "jane@example.com")
        let recipient = EmailAddress(name: "Bob", address: "bob@example.com")
        let cc = EmailAddress(address: "carol@example.com")
        let bcc = EmailAddress(name: "Archive", address: "archive@example.com")
        let email = Email(
            sender: sender, recipients: [recipient], ccRecipients: [cc], bccRecipients: [bcc],
            subject: "Hello", textBody: "Body"
        )

        let header = Message(email: email).header

        #expect(header.fromAddress == sender)
        #expect(header.toAddresses == [recipient])
        #expect(header.ccAddresses == [cc])
        #expect(header.bccAddresses == [bcc])
    }

    @Test
    func testDomainLiteralsAreNotSplitAtColonsOrCommas() throws {
        let eml = "From: ops@[IPv6:2001:db8::1]\r\n"
            + "To: user@[IPv6:2001:db8::1], Bob <bob@example.com>\r\n"
            + "Subject: Literal\r\n\r\nBody\r\n"

        let message = try Message(emlData: Data(eml.utf8))

        #expect(message.header.fromAddress == EmailAddress(address: "ops@[IPv6:2001:db8::1]"))
        #expect(message.header.toAddresses == [
            EmailAddress(address: "user@[IPv6:2001:db8::1]"),
            EmailAddress(name: "Bob", address: "bob@example.com")
        ])
    }

    @Test
    func testMSGWithoutTransportHeadersFillsStructuredAddresses() throws {
        let recipient: (String, String, Int32) -> CFBNode = { index, address, type in
            .storage(name: "__recip_version1.0_#0000000\(index)", children: mapiNodes([
                .unicode(.displayName, address == "bob@example.com" ? "Bob" : address),
                .unicode(.smtpAddress, address),
                .int32(.recipientType, type)
            ], isTopLevel: false))
        }
        let msg = CompoundFileBuilder.build(root: mapiNodes([
            .unicode(.subject, "Hallo"),
            .unicode(.body, "Text"),
            .unicode(.senderName, "Anna Beispiel"),
            .unicode(.senderSMTPAddress, "anna@example.com")
        ], isTopLevel: true, extra: [
            recipient("0", "bob@example.com", 1),
            recipient("1", "carol@example.com", 2),
            recipient("2", "dan@example.com", 3)
        ]))

        let header = try MSGParser.parse(msg).header

        #expect(header.fromAddress == EmailAddress(name: "Anna Beispiel", address: "anna@example.com"))
        #expect(header.toAddresses == [EmailAddress(name: "Bob", address: "bob@example.com")])
        #expect(header.ccAddresses == [EmailAddress(address: "carol@example.com")])
        #expect(header.bccAddresses == [EmailAddress(address: "dan@example.com")])
    }
}

extension FetchMessageInfoHandlerTests {
    // MARK: - Consumers Prefer Structured Addresses

    @Test
    func testEmailFromMessagePrefersStructuredAddresses() throws {
        // Legacy strings a string parser cannot recover; structured values exact.
        var header = MessageInfo(sequenceNumber: SequenceNumber(1))
        header.from = "Friends: Alice <alice@example.com>;"
        header.to = ["Team: Bob <bob@example.com>;"]
        header.fromAddress = EmailAddress(name: "Alice", address: "alice@example.com")
        header.toAddresses = [EmailAddress(name: "Bob", address: "bob@example.com")]

        let email = try Email(message: Message(header: header, parts: []))

        #expect(email.sender == EmailAddress(name: "Alice", address: "alice@example.com"))
        #expect(email.recipients == [EmailAddress(name: "Bob", address: "bob@example.com")])
    }

    @Test
    func testSendDraftAddressesPreferStructuredAddresses() throws {
        var header = MessageInfo(sequenceNumber: SequenceNumber(1))
        header.from = "Alice <alice@example.com>"
        header.to = ["\"Doe, Jane\" <jane@example.com>"]
        header.fromAddress = EmailAddress(name: "Alice", address: "alice@example.com")
        header.toAddresses = [EmailAddress(name: "Doe, Jane", address: "jane@example.com")]
        header.bccAddresses = [EmailAddress(address: "archive@example.com")]

        let (sender, recipients) = try IMAPServer.sendDraftAddresses(from: header)

        #expect(sender.address == "alice@example.com")
        #expect(recipients.map(\.address) == ["jane@example.com", "archive@example.com"])
    }
}

extension FetchMessageInfoHandlerTests {
    // MARK: - Comments and Serialization

    @Test
    func testCommentsBetweenNameWordsActAsSpace() throws {
        let eml = "From: John(comment)Doe <john@example.com>\r\n"
            + "To: Jane (the boss) Roe <jane@example.com>, <bob(x)@example.com>\r\n"
            + "Subject: CFWS\r\n\r\nBody\r\n"

        let message = try Message(emlData: Data(eml.utf8))

        #expect(message.header.fromAddress == EmailAddress(name: "John Doe", address: "john@example.com"))
        #expect(message.header.toAddresses == [
            EmailAddress(name: "Jane Roe", address: "jane@example.com"),
            EmailAddress(address: "bob@example.com")
        ])
    }

    @Test
    func testEMLSerializationWritesStructuredOnlyAddresses() throws {
        var header = MessageInfo(sequenceNumber: SequenceNumber(1), subject: "Structured")
        header.fromAddress = EmailAddress(name: "Doe, Jane", address: "jane@example.com")
        header.toAddresses = [EmailAddress(name: "Bob", address: "bob@example.com")]
        header.bccAddresses = [EmailAddress(address: "archive@example.com")]
        let message = Message(header: header, parts: [])

        let reparsed = try Message(emlData: try message.emlData())

        #expect(header.description.contains("From: \"Doe, Jane\" <jane@example.com>"))
        #expect(reparsed.header.fromAddress == header.fromAddress)
        #expect(reparsed.header.toAddresses == header.toAddresses)
        #expect(reparsed.header.bccAddresses == header.bccAddresses)
    }
}

extension FetchMessageInfoHandlerTests {
    // MARK: - Phrases, Completeness and Header Safety

    @Test
    func testMixedQuotedAndAtomPhraseIsKept() throws {
        let eml = "To: \"John\" Doe <john@example.com>, bob@example.com\r\nSubject: x\r\n\r\nBody\r\n"

        let message = try Message(emlData: Data(eml.utf8))

        #expect(message.header.toAddresses == [
            EmailAddress(name: "John Doe", address: "john@example.com"),
            EmailAddress(address: "bob@example.com")
        ])
    }

    @Test
    func testUnparseableMemberLeavesStructuredListEmpty() throws {
        // A partial structured list would silently drop a recipient for callers
        // that prefer it; an empty one sends them to the legacy strings instead.
        let eml = "To: bob@example.com, not an address\r\nSubject: x\r\n\r\nBody\r\n"

        let message = try Message(emlData: Data(eml.utf8))

        #expect(message.header.to.count == 2)
        #expect(message.header.toAddresses.isEmpty)
    }

    @Test
    func testStructuredAddressesCannotInjectHeaders() throws {
        var header = MessageInfo(sequenceNumber: SequenceNumber(1), subject: "Injection")
        header.fromAddress = EmailAddress(address: "victim@example.com\r\nBcc: attacker@example.com")
        header.toAddresses = [EmailAddress(name: "Bob", address: "bob@example.com\r\nX-Evil: 1")]

        let eml = String(bytes: try Message(header: header, parts: []).emlData(), encoding: .utf8) ?? ""

        #expect(!eml.contains("\r\nBcc:"))
        #expect(!eml.contains("\r\nX-Evil:"))
    }

    @Test
    func testControlCharactersNeverReachStructuredAddresses() throws {
        let msg = CompoundFileBuilder.build(root: mapiNodes([
            .unicode(.subject, "Hallo"),
            .unicode(.senderName, "Anna"),
            .unicode(.senderSMTPAddress, "anna@example.com\r\nBcc: attacker@example.com")
        ], isTopLevel: true))

        let header = try MSGParser.parse(msg).header

        #expect(header.fromAddress == nil)
    }
}

extension FetchMessageInfoHandlerTests {
    // MARK: - Quoted-Pairs and Encoded Names

    @Test
    func testQuotedPairsInPhraseSurvive() throws {
        let eml = "To: \"John \\\"Ace\\\"\" Doe <john@example.com>, bob@example.com\r\nSubject: x\r\n\r\nBody\r\n"

        let message = try Message(emlData: Data(eml.utf8))

        #expect(message.header.toAddresses == [
            EmailAddress(name: "John \"Ace\" Doe", address: "john@example.com"),
            EmailAddress(address: "bob@example.com")
        ])
        // The quoted word after an atom is unescaped too.
        #expect(EMLParser.parseStructuredAddressList(#"Doe "J\"r" <e@example.com>"#)
            == [EmailAddress(name: #"Doe J"r"#, address: "e@example.com")])
    }

    @Test
    func testEncodedNameCannotSmuggleUnsafeAddress() throws {
        var header = MessageInfo(sequenceNumber: SequenceNumber(1), subject: "Injection")
        header.fromAddress = EmailAddress(
            name: "Täglicher Bericht", address: "victim@example.com\r\nBcc: attacker@example.com")
        header.toAddresses = [EmailAddress(name: "Zoë", address: "bob@example.com\r\nX-Evil: 1")]

        let eml = String(bytes: try Message(header: header, parts: []).emlData(), encoding: .utf8) ?? ""

        #expect(!eml.contains("\r\nBcc:"))
        #expect(!eml.contains("\r\nX-Evil:"))
        // The shared formatter itself never emits a control character.
        #expect(!header.fromAddress!.headerString().contains { $0.isNewline })
    }
}

extension FetchMessageInfoHandlerTests {
    // MARK: - RFC 5322 Lexical Edge Cases

    @Test(arguments: [
        // A comment in a bare addr-spec is not part of the address.
        ("bob(comment)@example.com", EmailAddress(address: "bob@example.com")),
        ("bob@example.com (Bob)", EmailAddress(address: "bob@example.com")),
        // Adjacent words with no whitespace between them stay joined.
        (#""John"Doe <john@example.com>"#, EmailAddress(name: "JohnDoe", address: "john@example.com")),
        // Only a whole word that is an encoded-word is decoded.
        (#"abc=?UTF-8?Q?def?= "John" <john@example.com>"#,
         EmailAddress(name: "abc=?UTF-8?Q?def?= John", address: "john@example.com")),
        // Whitespace between adjacent encoded-words is not part of the text.
        ("=?UTF-8?Q?Ja?= =?UTF-8?Q?ne?= <jane@example.com>", EmailAddress(name: "Jane", address: "jane@example.com")),
        // An obsolete source route is not part of the address.
        ("<@relay.example:john@example.com>", EmailAddress(address: "john@example.com"))
    ])
    func testLexicalEdgeCases(value: String, expected: EmailAddress) {
        #expect(EMLParser.parseStructuredAddressList(value) == [expected])
    }

    @Test
    func testSerializationKeepsLegalTabInQuotedLocalPart() throws {
        var header = MessageInfo(sequenceNumber: SequenceNumber(1), subject: "Tab")
        header.toAddresses = [EmailAddress(address: "\"first\tlast\"@example.com")]

        let eml = String(bytes: try Message(header: header, parts: []).emlData(), encoding: .utf8) ?? ""

        #expect(eml.contains("To: \"first\tlast\"@example.com\r\n"))
    }
}
