import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite(.timeLimit(.minutes(1)))
struct FetchMessageInfoHandlerTests {
    @Test
    func testSingleFetchPopulatesThreadingProperties() async throws {
        let headerBlock = """
        In-Reply-To: <root@example.com>\r
        References: <root@example.com> <child@example.com>\r
        \r
        """

        let infos = try await executeFetch(
            [
                fetchResponse(
                    sequenceNumber: 1,
                    envelope: envelopeAttribute(
                        messageId: "<reply@example.com>",
                        inReplyTo: "<root@example.com>"
                    ),
                    headerBlock: headerBlock
                ),
                "A001 OK FETCH completed\r\n",
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].inReplyTo == MessageID("root@example.com"))
        #expect(infos[0].references == [MessageID("<root@example.com>")!, MessageID("<child@example.com>")!])
    }

    @Test
    func testBulkFetchPopulatesThreadingPropertiesForEachMessage() async throws {
        let firstHeader = """
        In-Reply-To: <root-a@example.com>\r
        References: <root-a@example.com>\r
        \r
        """
        let secondHeader = """
        References: <root-b@example.com> <child-b@example.com>\r
        \r
        """

        let infos = try await executeFetch(
            [
                fetchResponse(
                    sequenceNumber: 1,
                    envelope: envelopeAttribute(
                        messageId: "<reply-a@example.com>",
                        inReplyTo: "<root-a@example.com>"
                    ),
                    headerBlock: firstHeader
                ),
                fetchResponse(
                    sequenceNumber: 2,
                    envelope: envelopeAttribute(messageId: "<reply-b@example.com>"),
                    headerBlock: secondHeader
                ),
                "A001 OK FETCH completed\r\n",
            ]
        )

        #expect(infos.count == 2)
        #expect(infos[0].inReplyTo == MessageID("root-a@example.com"))
        #expect(infos[0].references == [MessageID("<root-a@example.com>")!])
        #expect(infos[1].inReplyTo == nil)
        #expect(infos[1].references == [MessageID("<root-b@example.com>")!, MessageID("<child-b@example.com>")!])
    }

    @Test
    func testMissingThreadingHeadersStayAbsent() async throws {
        let headerBlock = """
        Subject: No thread headers here\r
        X-Test: value\r
        \r
        """

        let infos = try await executeFetch(
            [
                fetchResponse(
                    sequenceNumber: 1,
                    envelope: envelopeAttribute(messageId: "<loner@example.com>"),
                    headerBlock: headerBlock
                ),
                "A001 OK FETCH completed\r\n",
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].inReplyTo == nil)
        #expect(infos[0].references == nil)
        #expect(infos[0].additionalFields?["subject"] == nil)
        #expect(infos[0].additionalFields?["x-test"] == "value")
    }

    @Test
    func testAdditionalFieldsArePopulated() async throws {
        let headerBlock = """
        List-ID: <announcements.example.com>\r
        List-Unsubscribe: <https://example.com/unsubscribe>\r
        X-Newsletter-ID: 12345\r
        In-Reply-To: <root@example.com>\r
        References: <root@example.com>\r
        \r
        """

        let infos = try await executeFetch(
            [
                fetchResponse(
                    sequenceNumber: 1,
                    envelope: envelopeAttribute(
                        messageId: "<msg@example.com>",
                        inReplyTo: "<root@example.com>"
                    ),
                    headerBlock: headerBlock
                ),
                "A001 OK FETCH completed\r\n",
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].inReplyTo == MessageID("root@example.com"))
        #expect(infos[0].references == [MessageID("<root@example.com>")!])
        #expect(infos[0].additionalFields?["list-id"] == "<announcements.example.com>")
        #expect(infos[0].additionalFields?["list-unsubscribe"] == "<https://example.com/unsubscribe>")
        #expect(infos[0].additionalFields?["x-newsletter-id"] == "12345")
        #expect(infos[0].additionalFields?["in-reply-to"] == nil)
        #expect(infos[0].additionalFields?["references"] == nil)
    }

    private func executeFetch(_ rawResponses: [String]) async throws -> [MessageInfo] {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

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

    private func fetchResponse(sequenceNumber: Int, envelope: String, headerBlock: String) -> String {
        "* \(sequenceNumber) FETCH (ENVELOPE \(envelope) BODY[HEADER] {\(headerBlock.utf8.count)}\r\n\(headerBlock))\r\n"
    }

    private func envelopeAttribute(messageId: String, inReplyTo: String? = nil) -> String {
        let inReplyToValue = inReplyTo.map { "\"\($0)\"" } ?? "NIL"
        return "(NIL NIL NIL NIL NIL NIL NIL NIL \(inReplyToValue) \"\(messageId)\")"
    }
}
