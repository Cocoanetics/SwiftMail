import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct EnableCommandTests {
    @Test
    func exactWireEncoding() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let tagged = EnableCommand(capabilities: [.qresync, .condStore]).toTaggedCommand(tag: "A001")
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(tagged)))

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        #expect(outbound.readString(length: outbound.readableBytes) == "A001 ENABLE QRESYNC CONDSTORE\r\n")
    }

    @Test
    func rejectsEmptyRequest() {
        #expect(throws: IMAPError.self) {
            try EnableCommand(capabilities: []).validate()
        }
    }

    @Test
    func returnsConfirmedCapabilitiesAfterTaggedOK() async throws {
        let result = try await execute(
            "* ENABLED QRESYNC\r\n"
                + "* CAPABILITY IMAP4rev1 ENABLE QRESYNC CONDSTORE\r\n"
                + "* ENABLED CONDSTORE QRESYNC X-EXTRA\r\n"
                + "A001 OK Enabled\r\n"
        )

        #expect(result == [.qresync, .condStore, Capability("X-EXTRA")])
    }

    @Test(arguments: ["* ENABLED\r\nA001 OK Enabled\r\n", "A001 OK Enabled\r\n"])
    func emptyConfirmationReturnsEmpty(_ response: String) async throws {
        #expect(try await execute(response).isEmpty)
    }

    @Test(arguments: ["NO", "BAD"])
    func rejectionAfterConfirmationFails(_ status: String) async throws {
        await #expect(throws: IMAPError.self) {
            _ = try await execute("* ENABLED QRESYNC\r\nA001 \(status) Rejected\r\n")
        }
    }

    @Test
    func unrelatedTagDoesNotCompleteHandler() async throws {
        let channel = NIOAsyncTestingChannel()
        let promise = channel.eventLoop.makePromise(of: [Capability].self)
        let handler = EnableHandler(commandTag: "A001", promise: promise)
        let response = Response.tagged(
            TaggedResponse(tag: "Z999", state: .ok(ResponseText(text: "Other command")))
        )

        #expect(!handler.processResponse(response))
        #expect(!handler.isCompleted)
        promise.fail(IMAPError.commandFailed("Test complete"))
    }

    private func execute(_ rawResponse: String) async throws -> [Capability] {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: [Capability].self)
        let handler = EnableHandler(commandTag: "A001", promise: promise)
        try await channel.pipeline.addHandler(handler)

        let command = TaggedCommand(tag: "A001", command: .enable([.qresync]))
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        var input = channel.allocator.buffer(capacity: rawResponse.utf8.count)
        input.writeString(rawResponse)
        try await channel.writeInbound(input)
        return try await promise.futureResult.get()
    }
}
