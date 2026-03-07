import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

struct FetchMessageInfoHandlerTests {
    @Test
    func testSingleFetchPopulatesThreadingAdditionalFields() async throws {
        let headerBlock = """
        In-Reply-To: <root@example.com>\r
        References: <root@example.com> <child@example.com>\r
        \r
        """

        let infos = try await executeFetch(
            [
                fetchResponse(sequenceNumber: 1, headerBlock: headerBlock),
                "A001 OK FETCH completed\r\n",
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].additionalFields?["in-reply-to"] == "<root@example.com>")
        #expect(infos[0].additionalFields?["references"] == "<root@example.com> <child@example.com>")
    }

    @Test
    func testBulkFetchPopulatesThreadingAdditionalFieldsForEachMessage() async throws {
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
                fetchResponse(sequenceNumber: 1, headerBlock: firstHeader),
                fetchResponse(sequenceNumber: 2, headerBlock: secondHeader),
                "A001 OK FETCH completed\r\n",
            ]
        )

        #expect(infos.count == 2)
        #expect(infos[0].additionalFields?["in-reply-to"] == "<root-a@example.com>")
        #expect(infos[0].additionalFields?["references"] == "<root-a@example.com>")
        #expect(infos[1].additionalFields?["in-reply-to"] == nil)
        #expect(infos[1].additionalFields?["references"] == "<root-b@example.com> <child-b@example.com>")
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
                fetchResponse(sequenceNumber: 1, headerBlock: headerBlock),
                "A001 OK FETCH completed\r\n",
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].additionalFields?["in-reply-to"] == nil)
        #expect(infos[0].additionalFields?["references"] == nil)
    }

    private func executeFetch(_ rawResponses: [String]) async throws -> [MessageInfo] {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let promise = channel.eventLoop.makePromise(of: [MessageInfo].self)
        let handler = FetchMessageInfoHandler(commandTag: "A001", promise: promise)
        try await channel.pipeline.addHandler(handler)

        let command = TaggedCommand(tag: "A001", command: .noop)
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))
        _ = try channel.readOutbound(as: ByteBuffer.self)

        for rawResponse in rawResponses {
            var buffer = channel.allocator.buffer(capacity: rawResponse.utf8.count)
            buffer.writeString(rawResponse)
            try channel.writeInbound(buffer)
        }

        return try await promise.futureResult.get()
    }

    private func fetchResponse(sequenceNumber: Int, headerBlock: String) -> String {
        "* \(sequenceNumber) FETCH (BODY[HEADER] {\(headerBlock.utf8.count)}\r\n\(headerBlock))\r\n"
    }
}
