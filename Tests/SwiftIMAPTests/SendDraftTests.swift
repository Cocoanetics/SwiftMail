import Foundation
@testable import SwiftMail
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SendDraftTests {
    // MARK: - parseEmailAddresses (single address)

    @Test
    func parseEmailAddressPlain() {
        let results = IMAPServer.parseEmailAddresses(from: "user@example.com")
        #expect(results.count == 1)
        #expect(results[0].address == "user@example.com")
        #expect(results[0].name == nil)
    }

    @Test
    func parseEmailAddressWithDisplayName() {
        let results = IMAPServer.parseEmailAddresses(from: "John Doe <john@example.com>")
        #expect(results.count == 1)
        #expect(results[0].address == "john@example.com")
        #expect(results[0].name == "John Doe")
    }

    @Test
    func parseEmailAddressWithQuotedDisplayName() {
        let results = IMAPServer.parseEmailAddresses(from: "\"Doe, John\" <john@example.com>")
        #expect(results.count == 1)
        #expect(results[0].address == "john@example.com")
        #expect(results[0].name == "Doe, John")
    }

    @Test
    func parseEmailAddressAngleBracketsOnly() {
        let results = IMAPServer.parseEmailAddresses(from: "<noreply@example.com>")
        #expect(results.count == 1)
        #expect(results[0].address == "noreply@example.com")
        #expect(results[0].name == nil)
    }

    @Test
    func parseEmailAddressTrimsWhitespace() {
        let results = IMAPServer.parseEmailAddresses(from: "  user@example.com  ")
        #expect(results.count == 1)
        #expect(results[0].address == "user@example.com")
        #expect(results[0].name == nil)
    }

    // MARK: - parseEmailAddresses (RFC 2822 group syntax)

    @Test
    func parseEmailAddressesGroupSyntax() {
        let results = IMAPServer.parseEmailAddresses(from: "Team: alice@example.com, bob@example.com;")
        #expect(results.count == 2)
        #expect(results[0].address == "alice@example.com")
        #expect(results[1].address == "bob@example.com")
    }

    @Test
    func parseEmailAddressesGroupSyntaxWithNames() {
        let results = IMAPServer.parseEmailAddresses(from: "Friends: Alice <alice@example.com>, Bob <bob@example.com>;")
        #expect(results.count == 2)
        #expect(results[0].address == "alice@example.com")
        #expect(results[0].name == "Alice")
        #expect(results[1].address == "bob@example.com")
        #expect(results[1].name == "Bob")
    }

    @Test
    func parseEmailAddressesGroupSyntaxEmpty() {
        // Empty group should return no addresses
        let results = IMAPServer.parseEmailAddresses(from: "Undisclosed recipients:;")
        #expect(results.isEmpty)
    }

    @Test
    func parseEmailAddressesGroupSyntaxMixed() {
        let input = "Sales: plain@example.com, Named <named@example.com>, <brackets@example.com>;"
        let results = IMAPServer.parseEmailAddresses(from: input)
        #expect(results.count == 3)
        #expect(results[0].address == "plain@example.com")
        #expect(results[1].address == "named@example.com")
        #expect(results[1].name == "Named")
        #expect(results[2].address == "brackets@example.com")
    }
}
