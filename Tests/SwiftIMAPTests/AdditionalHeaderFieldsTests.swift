import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct AdditionalHeaderFieldsTests {
    @Test
    func testRepeatedAdditionalFieldsArePreservedInOrder() async throws {
        let headerBlock = """
        List-Unsubscribe: <mailto:leave@example.com>\r
        List-Unsubscribe: <https://example.com/unsubscribe>\r
        \r
        """

        let infos = try await executeFetch(
            [
                fetchResponse(
                    sequenceNumber: 1,
                    envelope: envelopeAttribute(messageId: "<msg@example.com>"),
                    headerFields: ["List-Unsubscribe"],
                    headerBlock: headerBlock
                ),
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(infos.count == 1)

        let fields = infos[0].additionalHeaderFields?.filter { $0.name == "list-unsubscribe" }
        #expect(fields?.count == 2)
        #expect(fields?[0].value == "<mailto:leave@example.com>")
        #expect(fields?[1].value == "<https://example.com/unsubscribe>")

        #expect(infos[0].additionalFields?["list-unsubscribe"] == "<https://example.com/unsubscribe>")
    }

    @Test
    func testDirectlyConstructedFieldMatchesParsedField() async throws {
        let headerBlock = """
        List-Unsubscribe: <mailto:leave@example.com>\r
        \r
        """

        let infos = try await executeFetch(
            [
                fetchResponse(
                    sequenceNumber: 1,
                    envelope: envelopeAttribute(messageId: "<msg@example.com>"),
                    headerFields: ["List-Unsubscribe"],
                    headerBlock: headerBlock
                ),
                "A001 OK FETCH completed\r\n"
            ]
        )

        let parsed = try #require(infos.first?.additionalHeaderFields?.first)

        // A caller writing the header the way it appears on the wire must land on
        // the same value, or equality and name filtering would depend on where the
        // field came from.
        #expect(HeaderField(name: "List-Unsubscribe", value: " <mailto:leave@example.com> ") == parsed)
    }

    @Test
    func testHeaderFieldNormalizesNameCaseFoldedValueAndDecodedInput() throws {
        let mixedCase = HeaderField(name: "  List-Unsubscribe  ", value: "  <mailto:leave@example.com>  ")
        #expect(mixedCase.name == "list-unsubscribe")
        #expect(mixedCase.value == "<mailto:leave@example.com>")

        // Folded values rejoin with a single space, as the parser produces them.
        #expect(HeaderField(name: "x", value: "first\r\n  second\r\n\tthird").value == "first second third")

        // Decoding is a construction path too — it must not smuggle in raw input.
        let raw = Data(#"{"name":"List-Unsubscribe","value":"  <mailto:leave@example.com>  "}"#.utf8)
        #expect(try JSONDecoder().decode(HeaderField.self, from: raw) == mixedCase)
    }

    @Test
    func testAdditionalHeaderFieldsCodableRoundTrip() throws {
        let fields: [HeaderField] = [
            HeaderField(name: "list-unsubscribe", value: "<mailto:leave@example.com>"),
            HeaderField(name: "list-unsubscribe", value: "<https://example.com/unsubscribe>")
        ]
        var info = MessageInfo(sequenceNumber: SequenceNumber(1))
        info.additionalHeaderFields = fields

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(MessageInfo.self, from: data)

        #expect(decoded.additionalHeaderFields?.count == 2)
        #expect(decoded.additionalHeaderFields?[0].name == "list-unsubscribe")
        #expect(decoded.additionalHeaderFields?[0].value == "<mailto:leave@example.com>")
        #expect(decoded.additionalHeaderFields?[1].value == "<https://example.com/unsubscribe>")
    }

    private func executeFetch(_ rawResponses: [String]) async throws -> [MessageInfo] {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()

        let promise = channel.eventLoop.makePromise(of: [MessageInfo].self)
        let handler = FetchMessageInfoHandler(commandTag: "A001", promise: promise)
        try await channel.pipeline.addHandler(handler)

        let command = TaggedCommand(tag: "A001", command: .noop)
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        for rawResponse in rawResponses {
            var buffer = channel.allocator.buffer(capacity: rawResponse.utf8.count)
            buffer.writeString(rawResponse)
            try await channel.writeInbound(buffer)
        }

        return try await promise.futureResult.get()
    }

    private func fetchResponse(
        sequenceNumber: Int,
        envelope: String,
        headerFields: [String],
        headerBlock: String
    ) -> String {
        let fieldsList = headerFields.joined(separator: " ")
        let count = headerBlock.utf8.count
        return "* \(sequenceNumber) FETCH (ENVELOPE \(envelope)"
            + " BODY[HEADER.FIELDS (\(fieldsList))] {\(count)}\r\n"
            + "\(headerBlock))\r\n"
    }

    private func envelopeAttribute(messageId: String, inReplyTo: String? = nil) -> String {
        let inReplyToValue = inReplyTo.map { "\"\($0)\"" } ?? "NIL"
        return "(NIL NIL NIL NIL NIL NIL NIL NIL \(inReplyToValue) \"\(messageId)\")"
    }
}
