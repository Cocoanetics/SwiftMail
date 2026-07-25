import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct FetchGmailAttributesTests {

    // MARK: - Command encoding

    @Test
    func testWireFormatRequestsUIDAndGmailAttributes() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()

        let ids = UIDSet([UID(101), UID(205)])
        let command = FetchGmailAttributesCommand(identifierSet: ids)
        let tagged = command.toTaggedCommand(tag: "A001")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wire = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wire.contains("UID FETCH"))
        #expect(wire.contains("(UID X-GM-MSGID X-GM-THRID X-GM-LABELS)"))
        #expect(wire.contains("101,205") || wire.contains("101:205"))
    }

    // MARK: - Response decoding

    @Test
    func testHandlerDecodesMessageIDThreadIDAndMixedLabelSet() async throws {
        // Mixes a system label (\Inbox) with a user label ("Work") — system labels are
        // written unquoted on the wire while user labels are quoted IMAP strings.
        let attributesList = try await executeFetch(
            [
                "* 1 FETCH (UID 42 X-GM-MSGID 1278455344230334865 X-GM-THRID 1266894439832287888 "
                    + "X-GM-LABELS (\\Inbox \"Work\"))\r\n",
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(attributesList.count == 1)
        #expect(attributesList[0].uid == UID(42))
        #expect(attributesList[0].messageID == 1_278_455_344_230_334_865)
        #expect(attributesList[0].threadID == 1_266_894_439_832_287_888)
        #expect(attributesList[0].labels == ["\\Inbox", "Work"])
    }

    // MARK: - UID keying

    @Test
    func testResultsAreKeyedByReturnedUIDNotResponseOrder() async throws {
        // The server answers with UID 20 before UID 10 — out of both request order and
        // ascending order, which is how Gmail's IMAP server is free to respond. If the
        // caller ever keyed results by position instead of the UID actually returned,
        // this would silently swap the two messages' attributes.
        let (server, channel) = try await makeGmailHarness()

        let resultTask = Task {
            try await server.fetchGmailAttributes(for: UIDSet([UID(10), UID(20)]))
        }

        guard let commandLine = try await nextOutboundLine(from: channel) else {
            Issue.record("Expected outbound UID FETCH command")
            return
        }
        #expect(commandLine.contains("UID FETCH"))

        var response = channel.allocator.buffer(capacity: 0)
        response.writeString(
            "* 1 FETCH (UID 20 X-GM-MSGID 2222222222222222 X-GM-THRID 3333333333333333 "
                + "X-GM-LABELS (\\Inbox \"Work\"))\r\n"
                + "* 2 FETCH (UID 10 X-GM-MSGID 4444444444444444 X-GM-THRID 5555555555555555 "
                + "X-GM-LABELS (\\Important))\r\n"
                + "A001 OK UID FETCH completed\r\n"
        )
        try await channel.writeInbound(response)

        let result = try await resultTask.value

        #expect(result[UID(20)]?.messageID == 2_222_222_222_222_222)
        #expect(result[UID(20)]?.threadID == 3_333_333_333_333_333)
        #expect(result[UID(20)]?.labels == ["\\Inbox", "Work"])

        #expect(result[UID(10)]?.messageID == 4_444_444_444_444_444)
        #expect(result[UID(10)]?.threadID == 5_555_555_555_555_555)
        #expect(result[UID(10)]?.labels == ["\\Important"])
    }

    // MARK: - Validation

    @Test
    func testValidateThrowsForEmptyIdentifierSet() {
        #expect(throws: (any Error).self) {
            try FetchGmailAttributesCommand(identifierSet: UIDSet()).validate()
        }
    }

    // MARK: - Helpers

    private func executeFetch(_ rawResponses: [String]) async throws -> [GmailAttributeRecord] {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()

        let promise = channel.eventLoop.makePromise(of: [GmailAttributeRecord].self)
        let handler = FetchGmailAttributesHandler(commandTag: "A001", promise: promise)
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

    /// Wires an `IMAPServer`'s primary connection to an embedded channel so its public
    /// API can be driven end-to-end without a real socket, mirroring the harness used by
    /// `IMAPIdleCancellationTests`.
    private func makeGmailHarness() async throws -> (server: SwiftMail.IMAPServer, channel: NIOAsyncTestingChannel) {
        let server = SwiftMail.IMAPServer(host: "localhost", port: 143, useTLS: false)
        let connection = await server.primaryConnection

        let channel = NIOAsyncTestingChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 143)
        try await channel.connect(to: address)
        try await channel.addIMAPClientHandler()
        try await channel.pipeline.addHandler(connection.duplexLogger)
        try await channel.pipeline.addHandler(connection.responseBuffer)
        connection.replaceChannelForTesting(channel)

        return (server, channel)
    }

    private func nextOutboundLine(
        from channel: NIOAsyncTestingChannel,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async throws -> String? {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if var line = try await channel.readOutbound(as: ByteBuffer.self) {
                return line.readString(length: line.readableBytes)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }
}
