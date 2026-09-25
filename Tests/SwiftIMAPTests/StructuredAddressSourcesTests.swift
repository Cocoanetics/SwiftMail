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
}
