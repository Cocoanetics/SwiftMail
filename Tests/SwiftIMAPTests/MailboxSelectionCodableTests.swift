import Foundation
import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct MailboxSelectionCodableTests {
    @Test
    func legacyPayloadDecodesWithoutCheckpoint() throws {
        let json = #"{"messageCount":5,"recentCount":1,"firstUnseen":2,"uidValidity":777,"uidNext":51,"#
            + #""isReadOnly":false,"availableFlags":["seen"],"permanentFlags":["answered"]}"#
        let data = Data(json.utf8)
        let selection = try JSONDecoder().decode(Mailbox.Selection.self, from: data)

        #expect(selection.messageCount == 5)
        #expect(selection.highestModSequence == nil)
    }

    @Test
    func presentCheckpointRoundTripsAsNumber() throws {
        var selection = Mailbox.Selection()
        selection.highestModSequence = ModificationSequenceValue(exactly: UInt64(Int64.max))

        let data = try JSONEncoder().encode(selection)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["highestModSequence"] as? UInt64 == UInt64(Int64.max))

        let decoded = try JSONDecoder().decode(Mailbox.Selection.self, from: data)
        #expect(decoded.highestModSequence == selection.highestModSequence)
    }

    @Test
    func nilCheckpointIsOmitted() throws {
        let data = try JSONEncoder().encode(Mailbox.Selection())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["highestModSequence"] == nil)
    }

    @Test
    func unsupportedCheckpointFailsWithoutTrapping() {
        let json = #"{"messageCount":0,"recentCount":0,"firstUnseen":0,"uidValidity":0,"uidNext":0,"#
            + #""isReadOnly":false,"availableFlags":[],"permanentFlags":[],"#
            + #""highestModSequence":9223372036854775808}"#
        let data = Data(json.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Mailbox.Selection.self, from: data)
        }
    }
}
