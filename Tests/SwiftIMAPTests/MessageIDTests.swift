import Foundation
import Testing
@testable import SwiftMail

@Suite("MessageID Tests", .serialized, .timeLimit(.minutes(1)))
struct MessageIDTests {

    // MARK: - Parsing

    @Test("Parse angle-bracketed Message-ID")
    func testParseWithBrackets() {
        let id = MessageID("<local@domain.com>")
        #expect(id != nil)
        #expect(id?.localPart == "local")
        #expect(id?.domain == "domain.com")
    }

    @Test("Parse Message-ID without brackets")
    func testParseWithoutBrackets() {
        let id = MessageID("local@domain.com")
        #expect(id != nil)
        #expect(id?.localPart == "local")
        #expect(id?.domain == "domain.com")
    }

    @Test("Parse fails for string without @")
    func testParseNoAt() {
        #expect(MessageID("nodomain") == nil)
    }

    @Test("Parse fails for empty local part")
    func testParseEmptyLocal() {
        #expect(MessageID("<@domain.com>") == nil)
        #expect(MessageID("@domain.com") == nil)
    }

    @Test("Parse fails for empty domain")
    func testParseEmptyDomain() {
        #expect(MessageID("<local@>") == nil)
        #expect(MessageID("local@") == nil)
    }

    @Test("Parse splits on last @ for local parts containing @")
    func testParseLastAt() {
        let id = MessageID("user@host@domain.com")
        #expect(id != nil)
        #expect(id?.localPart == "user@host")
        #expect(id?.domain == "domain.com")
    }

    // MARK: - Description

    @Test("description always includes angle brackets")
    func testDescription() {
        let id = MessageID(localPart: "abc", domain: "example.com")
        #expect(id.description == "<abc@example.com>")
    }

    @Test("description from parsed input includes angle brackets")
    func testDescriptionFromParsed() {
        let id = MessageID("test@example.com")
        #expect(id?.description == "<test@example.com>")
    }

    // MARK: - Generate

    @Test("generate produces valid MessageID with non-empty localPart")
    func testGenerate() {
        let id = MessageID.generate(domain: "example.com")
        #expect(!id.localPart.isEmpty)
        #expect(id.domain == "example.com")
        #expect(id.description.hasPrefix("<"))
        #expect(id.description.hasSuffix(">"))
        #expect(id.description.contains("@example.com"))
    }

    @Test("generate produces unique IDs")
    func testGenerateUnique() {
        let id1 = MessageID.generate(domain: "example.com")
        let id2 = MessageID.generate(domain: "example.com")
        #expect(id1 != id2)
    }

    // MARK: - Round-trip

    @Test("Round-trip: parse(description) == original")
    func testRoundTrip() {
        let original = MessageID(localPart: "test-123", domain: "mail.example.com")
        let reparsed = MessageID(original.description)
        #expect(reparsed == original)
    }

    // MARK: - Codable

    @Test("Codable round-trip encodes as single string")
    func testCodableRoundTrip() throws {
        let original = MessageID(localPart: "coded", domain: "example.com")
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        // Verify it encodes as a string, not an object
        let jsonString = String(data: data, encoding: .utf8)!
        #expect(jsonString.contains("<coded@example.com>"))
        #expect(!jsonString.contains("localPart"))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MessageID.self, from: data)
        #expect(decoded == original)
    }

    @Test("Codable decoding fails for invalid format")
    func testCodableDecodingInvalid() {
        let json = Data("\"not-a-valid-id\"".utf8)
        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            try decoder.decode(MessageID.self, from: json)
        }
    }

    // MARK: - Hashable / Equatable

    @Test("Equatable: same parts are equal")
    func testEquatable() {
        let a = MessageID(localPart: "abc", domain: "example.com")
        let b = MessageID(localPart: "abc", domain: "example.com")
        #expect(a == b)
    }

    @Test("Equatable: different parts are not equal")
    func testNotEqual() {
        let a = MessageID(localPart: "abc", domain: "example.com")
        let b = MessageID(localPart: "xyz", domain: "example.com")
        #expect(a != b)
    }

    @Test("Hashable: equal values have same hash")
    func testHashable() {
        let a = MessageID(localPart: "abc", domain: "example.com")
        let b = MessageID(localPart: "abc", domain: "example.com")
        #expect(a.hashValue == b.hashValue)

        var set = Set<MessageID>()
        set.insert(a)
        set.insert(b)
        #expect(set.count == 1)
    }

    // MARK: - LosslessStringConvertible

    @Test("LosslessStringConvertible init")
    func testLosslessStringConvertible() {
        let id: MessageID? = MessageID("<lossless@example.com>")
        #expect(id != nil)
        #expect(String(describing: id!) == "<lossless@example.com>")
    }

    // MARK: - References Parsing

    @Test("parseMessageIDs handles space-separated IDs")
    func testParseReferencesSpaces() {
        let refs = FetchMessageInfoHandler.parseMessageIDs(from: "<a@x.com> <b@y.com> <c@z.com>")
        #expect(refs.count == 3)
        #expect(refs[0] == MessageID(localPart: "a", domain: "x.com"))
        #expect(refs[1] == MessageID(localPart: "b", domain: "y.com"))
        #expect(refs[2] == MessageID(localPart: "c", domain: "z.com"))
    }

    @Test("parseMessageIDs handles tab-separated IDs")
    func testParseReferencesTabs() {
        let refs = FetchMessageInfoHandler.parseMessageIDs(from: "<a@x.com>\t<b@y.com>")
        #expect(refs.count == 2)
        #expect(refs[0] == MessageID(localPart: "a", domain: "x.com"))
        #expect(refs[1] == MessageID(localPart: "b", domain: "y.com"))
    }

    @Test("parseMessageIDs handles folded whitespace (CRLF + space/tab)")
    func testParseReferencesFolded() {
        let refs = FetchMessageInfoHandler.parseMessageIDs(from: "<a@x.com>\r\n <b@y.com>\r\n\t<c@z.com>")
        #expect(refs.count == 3)
    }

    @Test("parseMessageIDs handles single ID")
    func testParseReferencesSingle() {
        let refs = FetchMessageInfoHandler.parseMessageIDs(from: "<only@one.com>")
        #expect(refs.count == 1)
        #expect(refs[0] == MessageID(localPart: "only", domain: "one.com"))
    }

    @Test("parseMessageIDs handles empty string")
    func testParseReferencesEmpty() {
        let refs = FetchMessageInfoHandler.parseMessageIDs(from: "")
        #expect(refs.isEmpty)
    }

    @Test("parseMessageIDs skips malformed IDs")
    func testParseReferencesSkipsMalformed() {
        let refs = FetchMessageInfoHandler.parseMessageIDs(from: "<good@ok.com> <nope> <also-good@fine.com>")
        #expect(refs.count == 2)
        #expect(refs[0].domain == "ok.com")
        #expect(refs[1].domain == "fine.com")
    }
}
