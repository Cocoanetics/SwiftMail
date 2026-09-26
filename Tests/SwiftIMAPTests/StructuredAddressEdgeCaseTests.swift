import Foundation
import NIO
import NIOEmbedded
import Testing
@testable import SwiftMail

/// RFC 5322 / 2047 / 6532 edge cases for structured addresses, split from
/// StructuredAddressSourcesTests to keep each file within the lint limits.
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
        ("<@relay.example:john@example.com>", EmailAddress(address: "john@example.com")),
        // ...and it ends at the first colon, not one inside the local-part.
        (#"<@relay.example:"john:doe"@example.com>"#, EmailAddress(address: #""john:doe"@example.com"#)),
        // Legal whitespace inside a quoted local-part is kept.
        ("\"first\tlast\"@example.com", EmailAddress(address: "\"first\tlast\"@example.com")),
        // Domain-literal text is not address syntax, and its whitespace is kept.
        ("user@[tag<value]", EmailAddress(address: "user@[tag<value]")),
        ("user@[tag value]", EmailAddress(address: "user@[tag value]")),
        ("Ops <ops@[tag:v <x>]>", EmailAddress(name: "Ops", address: "ops@[tag:v <x>]")),
        (#"Ann <user@[a"b]>"#, EmailAddress(name: "Ann", address: #"user@[a"b]"#)),
        // RFC whitespace is SP and HTAB only; other Unicode spaces are mailbox data.
        ("first\u{00A0}last@example.com", EmailAddress(address: "first\u{00A0}last@example.com")),
        ("Ann\u{2003}Lee <ann@example.com>", EmailAddress(name: "Ann\u{2003}Lee", address: "ann@example.com")),
        // An encoded-word must be delimited by whitespace; next to another word it is literal.
        (#"=?UTF-8?Q?John?="Doe" <john@example.com>"#,
         EmailAddress(name: "=?UTF-8?Q?John?=Doe", address: "john@example.com")),
        (#""Ann"=?UTF-8?Q?Lee?= <ann@example.com>"#,
         EmailAddress(name: "Ann=?UTF-8?Q?Lee?=", address: "ann@example.com")),
        // A comment between encoded-words is a space; only whitespace is dropped.
        ("=?UTF-8?Q?John?= (team) =?UTF-8?Q?Doe?= <john@example.com>",
         EmailAddress(name: "John Doe", address: "john@example.com"))
    ])
    func testLexicalEdgeCases(value: String, expected: EmailAddress) {
        #expect(EMLParser.parseStructuredAddressList(value) == [expected])
    }

    @Test
    func testQuoteInDomainLiteralDoesNotSwallowTheList() {
        #expect(EMLParser.parseStructuredAddressList(#"user@[a"b], bob@example.com"#) == [
            EmailAddress(address: #"user@[a"b]"#),
            EmailAddress(address: "bob@example.com")
        ])
    }

    @Test
    func testSerializationKeepsLegalTabInQuotedLocalPart() throws {
        var header = MessageInfo(sequenceNumber: SequenceNumber(1), subject: "Tab")
        header.toAddresses = [EmailAddress(address: "\"first\tlast\"@example.com")]

        let eml = String(bytes: try Message(header: header, parts: []).emlData(), encoding: .utf8) ?? ""

        #expect(eml.contains("To: \"first\tlast\"@example.com\r\n"))
    }
}

extension FetchMessageInfoHandlerTests {
    // MARK: - Unicode Scalars and Controls

    @Test
    func testDelimiterFollowedByCombiningMarkIsStillADelimiter() {
        // The quote and the combining accent form one Swift Character.
        let value = "\"\u{0301}Doe, Jane\" <jane@example.com>, bob@example.com"

        #expect(EMLParser.parseStructuredAddressList(value) == [
            EmailAddress(name: "\u{0301}Doe, Jane", address: "jane@example.com"),
            EmailAddress(address: "bob@example.com")
        ])
    }

    @Test
    func testNoForbiddenControlReachesAnAddressHeader() {
        let formatted = EmailAddress(name: "Zoë", address: "victim@example.com\u{000B}Bcc: attacker@example.com")
            .headerString()

        #expect(!formatted.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })
        #expect(!EmailAddress.isHeaderSafe("a@example.com\u{000B}"))
        #expect(!EmailAddress.isHeaderSafe("a@example.com\u{007F}"))
        #expect(EmailAddress.isHeaderSafe("\"a\tb\"@example.com"))
    }
}

extension FetchMessageInfoHandlerTests {
    // MARK: - Internationalized Addresses and MSG Precedence

    @Test
    func testVerticalTabIsNotWhitespaceButForbidden() {
        #expect(EMLParser.parseStructuredAddressList("a\u{000B}b@example.com").isEmpty)
    }

    @Test
    func testSerializationKeepsUTF8AddrSpecAsAddress() throws {
        var header = MessageInfo(sequenceNumber: SequenceNumber(1), subject: "EAI")
        header.fromAddress = EmailAddress(name: "Alice", address: "用户@example.com")
        header.toAddresses = [EmailAddress(address: "δοκιμή@example.com")]
        let message = Message(header: header, parts: [])

        let reparsed = try Message(emlData: try message.emlData())

        #expect(reparsed.header.fromAddress == header.fromAddress)
        #expect(reparsed.header.toAddresses == header.toAddresses)
    }

    @Test
    func testMSGTransportHeaderFieldWinsEvenWhenItsStructuredListIsEmpty() throws {
        let recipient = CFBNode.storage(name: "__recip_version1.0_#00000000", children: mapiNodes([
            .unicode(.displayName, "Bob"),
            .unicode(.smtpAddress, "bob@example.com"),
            .int32(.recipientType, 1)
        ], isTopLevel: false))
        let msg = CompoundFileBuilder.build(root: mapiNodes([
            .unicode(.subject, "Hallo"),
            .unicode(.transportMessageHeaders, "From: Anna <anna@example.com>\r\nTo: Undisclosed recipients:;\r\n\r\n")
        ], isTopLevel: true, extra: [recipient]))

        let header = try MSGParser.parse(msg).header

        #expect(header.to == ["Undisclosed recipients:;"])
        #expect(header.toAddresses.isEmpty)
    }
}

extension FetchMessageInfoHandlerTests {
    // MARK: - Forbidden Controls and Present-but-Empty MSG Fields

    @Test(arguments: ["a\u{0001}b@example.com", "A\u{0001}B <ab@example.com>", "a@example.com, b\u{0007}@example.com"])
    func testForbiddenControlAnywhereLeavesStructuredListEmpty(value: String) {
        #expect(EMLParser.parseStructuredAddressList(value).isEmpty)
    }

    @Test
    func testMSGPresentButEmptyHeaderFieldIsNotFilledFromMAPI() throws {
        let recipient = CFBNode.storage(name: "__recip_version1.0_#00000000", children: mapiNodes([
            .unicode(.displayName, "Bob"),
            .unicode(.smtpAddress, "bob@example.com"),
            .int32(.recipientType, 3)
        ], isTopLevel: false))
        let msg = CompoundFileBuilder.build(root: mapiNodes([
            .unicode(.subject, "Hallo"),
            .unicode(.transportMessageHeaders, "From: Anna <anna@example.com>\r\nBcc:\r\n\r\n")
        ], isTopLevel: true, extra: [recipient]))

        let header = try MSGParser.parse(msg).header

        #expect(header.bcc.isEmpty)
        #expect(header.bccAddresses.isEmpty)
    }
}
