import Foundation
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SMTPMessageIDTests {
    @Test
    func testMessageIDGenerate() {
        let id = MessageID.generate(domain: "example.com")
        #expect(id.domain == "example.com")
        #expect(!id.localPart.isEmpty)
        #expect(id.description.hasPrefix("<"))
        #expect(id.description.hasSuffix("@example.com>"))
    }

    @Test
    func testMessageIDParseValid() {
        let id = MessageID("<abc-123@example.com>")
        #expect(id != nil)
        #expect(id?.localPart == "abc-123")
        #expect(id?.domain == "example.com")
        #expect(id?.description == "<abc-123@example.com>")
    }

    @Test
    func testMessageIDParseWithoutBrackets() {
        let id = MessageID("abc-123@example.com")
        #expect(id != nil)
        #expect(id?.localPart == "abc-123")
        #expect(id?.domain == "example.com")
    }

    @Test
    func testMessageIDParseInvalid() {
        #expect(MessageID("no-at-sign") == nil)
        #expect(MessageID("@domain.com") == nil)
        #expect(MessageID("local@") == nil)
        #expect(MessageID("") == nil)
    }
}
