import Foundation
import NIO
import NIOIMAPCore
import Testing
@testable import SwiftMail

/// `Mailbox.Selection.messageCountReported` tells an `EXISTS 0` the server sent
/// from an `EXISTS` response it left out, which both read as a count of 0.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SelectExistsReportedTests {
    @Test
    func selectWithoutExistsDoesNotReportACount() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.imap4rev1])
        let operation = Task { try await harness.server.selectMailbox("INBOX") }
        #expect(try await nextQResyncOutboundLine(from: harness.channel) == "A001 SELECT \"INBOX\"\r\n")
        try await writeQResyncInbound(
            harness.channel,
            "* OK [UIDVALIDITY 42] Ok\r\n"
                + "* OK [UIDNEXT 4] Predicted next UID\r\n"
                + "A001 OK [READ-WRITE] Selected\r\n"
        )
        let selection = try await operation.value
        #expect(selection.messageCount == 0)
        #expect(!selection.messageCountReported)
        try await harness.channel.close()
    }

    @Test
    func selectWithExplicitExistsZeroReportsTheCount() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.imap4rev1])
        let operation = Task { try await harness.server.selectMailbox("INBOX") }
        #expect(try await nextQResyncOutboundLine(from: harness.channel) == "A001 SELECT \"INBOX\"\r\n")
        try await writeQResyncInbound(
            harness.channel,
            "* 0 EXISTS\r\n"
                + "* OK [UIDVALIDITY 42] Ok\r\n"
                + "* OK [UIDNEXT 4] Predicted next UID\r\n"
                + "A001 OK [READ-WRITE] Selected\r\n"
        )
        let selection = try await operation.value
        #expect(selection.messageCount == 0)
        #expect(selection.messageCountReported)
        try await harness.channel.close()
    }

    @Test
    func reportedFlagSurvivesCodingAndOlderEncodingsDecodeAsNotReported() throws {
        var selection = Mailbox.Selection()
        selection.messageCountReported = true
        let data = try JSONEncoder().encode(selection)
        #expect(try JSONDecoder().decode(Mailbox.Selection.self, from: data).messageCountReported)

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "messageCountReported")
        let older = try JSONSerialization.data(withJSONObject: object)
        #expect(!(try JSONDecoder().decode(Mailbox.Selection.self, from: older).messageCountReported))
    }
}
