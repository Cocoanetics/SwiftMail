import Foundation
import Testing
@testable import SwiftMail

struct SendDraftTests {

    // MARK: - parseEmailAddresses (single address)

    @Test
    func testParseEmailAddressPlain() {
        let results = IMAPServer.parseEmailAddresses(from: "user@example.com")
        #expect(results.count == 1)
        #expect(results[0].address == "user@example.com")
        #expect(results[0].name == nil)
    }

    @Test
    func testParseEmailAddressWithDisplayName() {
        let results = IMAPServer.parseEmailAddresses(from: "John Doe <john@example.com>")
        #expect(results.count == 1)
        #expect(results[0].address == "john@example.com")
        #expect(results[0].name == "John Doe")
    }

    @Test
    func testParseEmailAddressWithQuotedDisplayName() {
        let results = IMAPServer.parseEmailAddresses(from: "\"Doe, John\" <john@example.com>")
        #expect(results.count == 1)
        #expect(results[0].address == "john@example.com")
        #expect(results[0].name == "Doe, John")
    }

    @Test
    func testParseEmailAddressAngleBracketsOnly() {
        let results = IMAPServer.parseEmailAddresses(from: "<noreply@example.com>")
        #expect(results.count == 1)
        #expect(results[0].address == "noreply@example.com")
        #expect(results[0].name == nil)
    }

    @Test
    func testParseEmailAddressTrimsWhitespace() {
        let results = IMAPServer.parseEmailAddresses(from: "  user@example.com  ")
        #expect(results.count == 1)
        #expect(results[0].address == "user@example.com")
        #expect(results[0].name == nil)
    }

    // MARK: - parseEmailAddresses (RFC 2822 group syntax)

    @Test
    func testParseEmailAddressesGroupSyntax() {
        let results = IMAPServer.parseEmailAddresses(from: "Team: alice@example.com, bob@example.com;")
        #expect(results.count == 2)
        #expect(results[0].address == "alice@example.com")
        #expect(results[1].address == "bob@example.com")
    }

    @Test
    func testParseEmailAddressesGroupSyntaxWithNames() {
        let results = IMAPServer.parseEmailAddresses(from: "Friends: Alice <alice@example.com>, Bob <bob@example.com>;")
        #expect(results.count == 2)
        #expect(results[0].address == "alice@example.com")
        #expect(results[0].name == "Alice")
        #expect(results[1].address == "bob@example.com")
        #expect(results[1].name == "Bob")
    }

    @Test
    func testParseEmailAddressesGroupSyntaxEmpty() {
        // Empty group should return no addresses
        let results = IMAPServer.parseEmailAddresses(from: "Undisclosed recipients:;")
        #expect(results.isEmpty)
    }

    @Test
    func testParseEmailAddressesGroupSyntaxMixed() {
        let results = IMAPServer.parseEmailAddresses(from: "Sales: plain@example.com, Named <named@example.com>, <brackets@example.com>;")
        #expect(results.count == 3)
        #expect(results[0].address == "plain@example.com")
        #expect(results[1].address == "named@example.com")
        #expect(results[1].name == "Named")
        #expect(results[2].address == "brackets@example.com")
    }
}
