import Foundation
import NIO
@preconcurrency import NIOIMAP
import Testing
@testable import SwiftMail

@Suite("Partial BODY.PEEK fetching", .serialized, .timeLimit(.minutes(3)))
struct PartialFetchTests {
    @Test("Command encodes offset and count on the wire")
    func commandWireFormat() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let command = FetchMessagePartCommand(
            identifier: UID(42),
            section: Section([2, 1]),
            range: 1_048_576...1_572_863
        )
        let tagged = command.toTaggedCommand(tag: "P001")
        try await channel.writeAndFlush(
            IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        )

        var outbound = try #require(await channel.readOutbound(as: ByteBuffer.self))
        #expect(outbound.readString(length: outbound.readableBytes)
            == "P001 UID FETCH 42 (BODY.PEEK[2.1]<1048576.524288>)\r\n")

        let sequenceChannel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let sequenceCommand = FetchMessagePartCommand(
            identifier: SwiftMail.SequenceNumber(42),
            section: Section([2, 1]),
            range: 0...3
        )
        try await sequenceChannel.writeAndFlush(IMAPClientHandler.OutboundIn.part(
            CommandStreamPart.tagged(sequenceCommand.toTaggedCommand(tag: "P002"))
        ))
        var sequenceOutbound = try #require(
            await sequenceChannel.readOutbound(as: ByteBuffer.self)
        )
        #expect(sequenceOutbound.readString(length: sequenceOutbound.readableBytes)
            == "P002 FETCH 42 (BODY.PEEK[2.1]<0.4>)\r\n")
    }

    @Test("Invalid ranges fail before connecting")
    func invalidRanges() async {
        let server = IMAPServer(host: "127.0.0.1", port: 9, useTLS: false)
        for (offset, count) in [
            (-1, 1),
            (0, 0),
            (Int(UInt32.max), 2),
            (Int(UInt32.max) + 1, 1),
            (0, Int(UInt32.max) + 1)
        ] {
            await #expect(throws: PartialFetchError.invalidRange) {
                _ = try await server.fetchPart(
                    section: Section([1]), of: UID(1), offset: offset, count: count
                )
            }
        }
    }

    #if os(macOS)
    @Test("Bounded wire fetches reconstruct more than 32 MiB")
    func reconstructsLargeBody() async throws {
        let body = Data(repeating: 0x61, count: 33 * 1024 * 1024 + 257)
        let fixture = try makeFixture(body: body)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let testServer = try IMAPTestServer(maildirURL: fixture.maildir)
        try testServer.start()

        try await testServer.run {
            let server = IMAPServer(
                host: "127.0.0.1",
                port: testServer.port,
                useTLS: false,
                responseBufferLimit: 4 * 1024 * 1024
            )
            try await server.connect()
            try await server.login(username: "testuser", password: "testpass")
            _ = try await server.selectMailbox("INBOX")

            let chunkSize = 1024 * 1024
            var assembled = Data()
            var offset = 0
            while offset < body.count {
                let chunk = try await server.fetchPart(
                    section: Section([1]), of: UID(1), offset: offset, count: chunkSize
                )
                assembled.append(chunk)
                offset += chunk.count
            }
            let eof = try await server.fetchPart(
                section: Section([1]), of: UID(1), offset: body.count, count: chunkSize
            )
            let sequenceChunk = try await server.fetchPart(
                section: Section([1]),
                of: SwiftMail.SequenceNumber(1),
                offset: 0,
                count: 4
            )

            #expect(assembled == body)
            #expect(eof.isEmpty)
            #expect(sequenceChunk == body.prefix(4))
            #expect(testServer.commandLog.filter { $0.contains("BODY.PEEK[1]<") }.count == 36)
            try await server.disconnect()
        }
    }

    @Test("Ignored and malformed ranges are rejected")
    func rejectsInvalidResponses() async throws {
        let cases: [(IMAPTestServer.PartialFetchBehavior, Data)] = [
            (.ignoreRange, Data(repeating: 0x61, count: 33 * 1024 * 1024 + 257)),
            (.wrongOffset, Data("small body".utf8))
        ]
        for (behavior, body) in cases {
            let fixture = try makeFixture(body: body)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let testServer = try IMAPTestServer(
                partialFetchBehavior: behavior,
                maildirURL: fixture.maildir
            )
            try testServer.start()
            try await testServer.run {
                let server = try await connectedServer(testServer)
                await #expect(throws: PartialFetchError.invalidResponse(
                    "section or partial origin did not match request"
                )) {
                    _ = try await server.fetchPart(
                        section: Section([1]), of: UID(1), offset: 3, count: 4
                    )
                }
                let remainedConnected = await server.isConnected
                #expect(!remainedConnected)
                try await server.connect()
                try await server.login(username: "testuser", password: "testpass")
                _ = try await server.selectMailbox("INBOX")
                #expect(testServer.acceptedConnectionCount == 2)
                #expect(try await !server.fetchStructure(UID(1)).isEmpty)
                try await server.disconnect()
            }
        }
    }

    @Test("No-match and unsupported-server outcomes stay distinct")
    func terminalOutcomes() async throws {
        let fixture = try makeFixture(body: Data("small body".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let normalServer = try IMAPTestServer(maildirURL: fixture.maildir)
        try normalServer.start()
        try await normalServer.run {
            let server = try await connectedServer(normalServer)
            let ordinaryPart = try await server.fetchPart(section: Section([1]), of: UID(1))
            #expect(ordinaryPart == Data("small body".utf8))
            await #expect(throws: PartialFetchError.messageNotFound) {
                _ = try await server.fetchPart(
                    section: Section([1]), of: UID(999), offset: 0, count: 4
                )
            }
            try await server.disconnect()
        }

        let rejectingServer = try IMAPTestServer(
            partialFetchBehavior: .rejectWithBad,
            maildirURL: fixture.maildir
        )
        try rejectingServer.start()
        try await rejectingServer.run {
            let server = try await connectedServer(rejectingServer)
            await #expect(throws: PartialFetchError.serverRejected) {
                _ = try await server.fetchPart(
                    section: Section([1]), of: UID(1), offset: 0, count: 4
                )
            }
            #expect(try await !server.fetchStructure(UID(1)).isEmpty)
            try await server.disconnect()
        }

        let temporaryFailureServer = try IMAPTestServer(
            partialFetchBehavior: .rejectWithNo,
            maildirURL: fixture.maildir
        )
        try temporaryFailureServer.start()
        try await temporaryFailureServer.run {
            let server = try await connectedServer(temporaryFailureServer)
            await #expect(throws: IMAPError.self) {
                _ = try await server.fetchPart(
                    section: Section([1]), of: UID(1), offset: 0, count: 4
                )
            }
            #expect(try await !server.fetchStructure(UID(1)).isEmpty)
            try await server.disconnect()
        }
    }

    private func connectedServer(_ testServer: IMAPTestServer) async throws -> SwiftMail.IMAPServer {
        let server = SwiftMail.IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
        try await server.connect()
        try await server.login(username: "testuser", password: "testpass")
        _ = try await server.selectMailbox("INBOX")
        return server
    }

    private func makeFixture(body: Data) throws -> (root: URL, maildir: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let maildir = root.appendingPathComponent("Maildir")
        let current = maildir.appendingPathComponent("cur")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: maildir.appendingPathComponent("new"),
            withIntermediateDirectories: true
        )
        var message = Data(("""
        From: Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: Partial fetch test\r
        Date: Thu, 01 Jan 1970 00:00:00 +0000\r
        Message-ID: <partial-fetch@example.com>\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: base64\r
        \r

        """).utf8)
        message.append(body)
        try message.write(to: current.appendingPathComponent("1.eml"))
        return (root, maildir)
    }
    #endif
}
