import Foundation
import Testing
@testable import SwiftMail

struct SendDraftTests {

    // MARK: - parseEmailAddress

    @Test
    func testParseEmailAddressPlain() {
        let result = IMAPServer.parseEmailAddress(from: "user@example.com")
        #expect(result.address == "user@example.com")
        #expect(result.name == nil)
    }

    @Test
    func testParseEmailAddressWithDisplayName() {
        let result = IMAPServer.parseEmailAddress(from: "John Doe <john@example.com>")
        #expect(result.address == "john@example.com")
        #expect(result.name == "John Doe")
    }

    @Test
    func testParseEmailAddressWithQuotedDisplayName() {
        let result = IMAPServer.parseEmailAddress(from: "\"Doe, John\" <john@example.com>")
        #expect(result.address == "john@example.com")
        #expect(result.name == "Doe, John")
    }

    @Test
    func testParseEmailAddressAngleBracketsOnly() {
        let result = IMAPServer.parseEmailAddress(from: "<noreply@example.com>")
        #expect(result.address == "noreply@example.com")
        #expect(result.name == nil)
    }

    @Test
    func testParseEmailAddressTrimsWhitespace() {
        let result = IMAPServer.parseEmailAddress(from: "  user@example.com  ")
        #expect(result.address == "user@example.com")
        #expect(result.name == nil)
    }
}
