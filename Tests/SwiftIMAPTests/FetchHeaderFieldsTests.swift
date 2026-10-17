import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite("Fetch header fields", .serialized, .timeLimit(.minutes(1)))
struct FetchHeaderFieldsTests {
    // MARK: - Command

    @Test("A UID set sends one UID FETCH of BODY.PEEK[HEADER.FIELDS (...)]")
    func uidFetchWireFormat() async throws {
        let command = FetchHeaderFieldsCommand(
            identifierSet: SwiftMail.UIDSet(SwiftMail.UID(7)...SwiftMail.UID(9)),
            fields: ["Reply-To", "Delivered-To", "Authentication-Results"]
        )
        let wire = try await encoded(command.toTaggedCommand(tag: "A001"))
        // swift-nio-imap writes each field name as a quoted string (an IMAP astring).
        let fields = #"("Reply-To" "Delivered-To" "Authentication-Results")"#
        #expect(wire == "A001 UID FETCH 7:9 (UID BODY.PEEK[HEADER.FIELDS \(fields)])\r\n")
    }

    @Test("A sequence number set sends a plain FETCH")
    func sequenceFetchWireFormat() async throws {
        let command = FetchHeaderFieldsCommand(
            identifierSet: SwiftMail.SequenceNumberSet(SwiftMail.SequenceNumber(1)...SwiftMail.SequenceNumber(2)),
            fields: ["Received"]
        )
        let wire = try await encoded(command.toTaggedCommand(tag: "A002"))
        #expect(wire == #"A002 FETCH 1:2 (UID BODY.PEEK[HEADER.FIELDS ("Received")])"# + "\r\n")
    }

    @Test("Empty sets, empty field lists and malformed field names are rejected before sending")
    func validation() throws {
        let uids = SwiftMail.UIDSet(SwiftMail.UID(1))
        #expect(throws: IMAPError.self) {
            try FetchHeaderFieldsCommand(identifierSet: SwiftMail.UIDSet(), fields: ["Received"]).validate()
        }
        #expect(throws: IMAPError.self) {
            try FetchHeaderFieldsCommand(identifierSet: uids, fields: []).validate()
        }
        for name in ["", "Reply-To:", "Reply To", "Dé"] {
            #expect(throws: IMAPError.self) {
                try FetchHeaderFieldsCommand(identifierSet: uids, fields: [name]).validate()
            }
        }
        try FetchHeaderFieldsCommand(identifierSet: uids, fields: ["X-Original-To", "ARC-Seal"]).validate()
    }

    // MARK: - Responses

    @Test("Each block is the server's bytes: repeated fields in order, folding and 8-bit bytes kept")
    func blocksAreRawAndOrdered() async throws {
        let lines: [String] = [
            "Delivered-To: alias@example.org\r\n",
            "Authentication-Results: mx.example.org;\r\n",
            "\tdkim=pass header.d=example.com\r\n",
            "Delivered-To: owner@example.net\r\n",
            "Authentication-Results: relay.example.net; spf=fail\r\n",
            "Reply-To: =?utf-8?q?Gr=C3=BC=C3=9Fe?= <reply@example.com>\r\n",
            "X-Legacy: caf"
        ]
        var first = Data(lines.joined().utf8)
        first.append(0xE9) // Latin-1 "é", not UTF-8
        first.append(contentsOf: Data("\r\n\r\n".utf8))
        let second = Data("Delivered-To: other@example.org\r\n\r\n".utf8)

        let fields = "Delivered-To Authentication-Results Reply-To X-Legacy"
        let blocks = try await executeFetch([
            response(sequenceNumber: 1, uid: 41, uidFirst: true, fields: fields, block: first),
            response(sequenceNumber: 2, uid: 42, uidFirst: true, fields: fields, block: second),
            Data("A001 OK FETCH completed\r\n".utf8)
        ])

        #expect(blocks == [SwiftMail.UID(41): first, SwiftMail.UID(42): second])
    }

    @Test("UID after the body section and field names echoed in another case still match")
    func uidAfterBodyAndUppercasedEcho() async throws {
        let block = Data("REPLY-TO: someone@example.com\r\n\r\n".utf8)
        let blocks = try await executeFetch([
            response(sequenceNumber: 3, uid: 77, uidFirst: false, fields: "REPLY-TO", block: block),
            Data("A001 OK FETCH completed\r\n".utf8)
        ])

        #expect(blocks == [SwiftMail.UID(77): block])
    }

    @Test("A message without the fields keeps its empty block; NIL bodies and unsolicited FETCHes are skipped")
    func emptyNilAndUnsolicited() async throws {
        let empty = Data("\r\n".utf8)
        let blocks = try await executeFetch([
            response(sequenceNumber: 1, uid: 10, uidFirst: true, fields: "Reply-To", block: empty),
            Data("* 5 FETCH (FLAGS (\\Seen))\r\n".utf8),
            Data("* 2 FETCH (UID 11 BODY[HEADER.FIELDS (Reply-To)] NIL)\r\n".utf8),
            Data("A001 OK FETCH completed\r\n".utf8)
        ])

        #expect(blocks == [SwiftMail.UID(10): empty])
    }

    @Test("A sequence number fetch is keyed by sequence number")
    func keyedBySequenceNumber() async throws {
        let block = Data("Received: from a\r\nReceived: from b\r\n\r\n".utf8)
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: [SwiftMail.SequenceNumber: Data].self)
        try await channel.pipeline.addHandler(
            FetchHeaderFieldsHandler<SwiftMail.SequenceNumber>(commandTag: "A001", promise: promise)
        )
        try await send(on: channel, [
            response(sequenceNumber: 4, uid: 99, uidFirst: true, fields: "Received", block: block),
            Data("A001 OK FETCH completed\r\n".utf8)
        ])

        #expect(try await promise.futureResult.get() == [SwiftMail.SequenceNumber(4): block])
    }

    @Test("A tagged NO fails the fetch")
    func taggedNoFails() async throws {
        await #expect(throws: IMAPError.self) {
            _ = try await executeFetch([Data("A001 NO [SERVERBUG] fetch failed\r\n".utf8)])
        }
    }

    @Test("In a UID fetch a header block without its UID fails the command; a sequence fetch keys it by number")
    func blockWithoutUID() async throws {
        let block = Data("Reply-To: someone@example.com\r\n\r\n".utf8)
        var withoutUID = Data("* 3 FETCH (BODY[HEADER.FIELDS (Reply-To)] {\(block.count)}\r\n".utf8)
        withoutUID.append(block)
        withoutUID.append(contentsOf: Data(")\r\n".utf8))
        let completed = Data("A001 OK FETCH completed\r\n".utf8)

        let error = await #expect(throws: IMAPError.self) {
            _ = try await executeFetch([withoutUID, completed])
        }
        #expect(error?.description.contains("without its UID") == true)

        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: [SwiftMail.SequenceNumber: Data].self)
        try await channel.pipeline.addHandler(
            FetchHeaderFieldsHandler<SwiftMail.SequenceNumber>(commandTag: "A001", promise: promise)
        )
        try await send(on: channel, [withoutUID, completed])
        #expect(try await promise.futureResult.get() == [SwiftMail.SequenceNumber(3): block])
    }

    @Test("A block of exactly the cap is kept whole and none of the streamed bytes stay in the history")
    func blockAtTheCapIsKept() async throws {
        let maximum = FetchHeaderFieldsHandler<SwiftMail.UID>.maximumHeaderBytes
        let (handler, promise) = streamedHandler(blocks: [(uid: 5, byteCount: maximum)])
        #expect(handler.untaggedResponses.isEmpty)

        _ = handler.processResponse(.tagged(TaggedResponse(tag: "A1", state: .ok(ResponseText(text: "done")))))
        let blocks = try await promise.futureResult.get()
        #expect(blocks[SwiftMail.UID(5)]?.count == maximum)
    }

    @Test("A block over the cap fails the command once the server has finished answering")
    func blockOverTheCapFails() async throws {
        let maximum = FetchHeaderFieldsHandler<SwiftMail.UID>.maximumHeaderBytes
        let (handler, promise) = streamedHandler(blocks: [(uid: 5, byteCount: maximum + 1), (uid: 6, byteCount: 10)])
        // The rest of the response is still consumed by this command.
        #expect(!handler.isCompleted)
        #expect(handler.untaggedResponses.isEmpty)

        _ = handler.processResponse(.tagged(TaggedResponse(tag: "A1", state: .ok(ResponseText(text: "done")))))
        let error = await #expect(throws: IMAPError.self) {
            _ = try await promise.futureResult.get()
        }
        #expect(error?.description.contains("UID 5 exceeds \(maximum) bytes") == true)
    }

    // MARK: - Helpers

    /// A handler that has been fed one streamed block per entry (UID first,
    /// `byteCount` bytes of `x`), without the tagged response.
    private func streamedHandler(
        blocks: [(uid: Int, byteCount: Int)]
    ) -> (FetchHeaderFieldsHandler<SwiftMail.UID>, EventLoopPromise<[SwiftMail.UID: Data]>) {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: [SwiftMail.UID: Data].self)
        let handler = FetchHeaderFieldsHandler<SwiftMail.UID>(commandTag: "A1", promise: promise)
        let section = SectionSpecifier.wholeMessageHeaderFields(["Received"])
        for (index, block) in blocks.enumerated() {
            _ = handler.processResponse(.fetch(.start(NIOIMAPCore.SequenceNumber(rawValue: UInt32(index + 1)))))
            _ = handler.processResponse(.fetch(.simpleAttribute(.uid(NIOIMAPCore.UID(rawValue: UInt32(block.uid))))))
            _ = handler.processResponse(.fetch(.streamingBegin(kind: .body(section: section, offset: nil),
                                                               byteCount: block.byteCount)))
            var remaining = block.byteCount
            while remaining > 0 {
                let count = min(remaining, 4096)
                let bytes = ByteBuffer(repeating: UInt8(ascii: "x"), count: count)
                _ = handler.processResponse(.fetch(.streamingBytes(bytes)))
                remaining -= count
            }
            _ = handler.processResponse(.fetch(.streamingEnd))
            _ = handler.processResponse(.fetch(.finish))
        }
        return (handler, promise)
    }

    private func executeFetch(_ rawResponses: [Data]) async throws -> [SwiftMail.UID: Data] {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: [SwiftMail.UID: Data].self)
        try await channel.pipeline.addHandler(
            FetchHeaderFieldsHandler<SwiftMail.UID>(commandTag: "A001", promise: promise)
        )
        try await send(on: channel, rawResponses)
        return try await promise.futureResult.get()
    }

    private func send(on channel: NIOAsyncTestingChannel, _ rawResponses: [Data]) async throws {
        let command = TaggedCommand(tag: "A001", command: .noop)
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        for rawResponse in rawResponses {
            var buffer = channel.allocator.buffer(capacity: rawResponse.count)
            buffer.writeBytes(rawResponse)
            try await channel.writeInbound(buffer)
        }
    }

    /// The bytes the client writes for a tagged command.
    private func encoded(_ command: TaggedCommand) async throws -> String {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))
        var wire = ""
        while let buffer = try await channel.readOutbound(as: ByteBuffer.self) {
            wire += String(buffer: buffer)
        }
        return wire
    }

    private func response(sequenceNumber: Int, uid: Int, uidFirst: Bool, fields: String, block: Data) -> Data {
        let body = "BODY[HEADER.FIELDS (\(fields))] {\(block.count)}\r\n"
        var data = Data("* \(sequenceNumber) FETCH (".utf8)
        if uidFirst {
            data.append(contentsOf: Data("UID \(uid) \(body)".utf8))
            data.append(block)
            data.append(contentsOf: Data(")\r\n".utf8))
        } else {
            data.append(contentsOf: Data(body.utf8))
            data.append(block)
            data.append(contentsOf: Data(" UID \(uid))\r\n".utf8))
        }
        return data
    }
}

@Suite("Fetch header fields in chunks", .timeLimit(.minutes(1)))
struct FetchHeaderFieldsChunkTests {
    @Test("A large set is split into chunks that carry the timeout; a set ending in * is sent whole")
    func chunks() throws {
        let uids = SwiftMail.UIDSet(SwiftMail.UID(1)...SwiftMail.UID(450))
        let byDefault = try FetchHeaderFieldsCommand.chunks(
            fields: ["Received"], identifierSet: uids, chunkSize: nil, timeoutSeconds: nil
        )
        #expect(byDefault.map(\.identifierSet.count) == [200, 200, 50])
        #expect(byDefault.map { $0.identifierSet.toArray().first } == [1, 201, 401].map { SwiftMail.UID($0) })
        #expect(byDefault.allSatisfy { $0.timeoutSeconds == 30 && $0.fields == ["Received"] })

        let three = SwiftMail.UIDSet([SwiftMail.UID(4), SwiftMail.UID(9), SwiftMail.UID(12)])
        let custom = try FetchHeaderFieldsCommand.chunks(
            fields: ["Received"], identifierSet: three, chunkSize: 2, timeoutSeconds: 90
        )
        #expect(custom.map { $0.identifierSet.toArray() } == [[4, 9], [12]].map { $0.map { SwiftMail.UID($0) } })
        #expect(custom.allSatisfy { $0.timeoutSeconds == 90 })

        let whole = try FetchHeaderFieldsCommand.chunks(
            fields: ["Received"], identifierSet: uids, chunkSize: 0, timeoutSeconds: nil
        )
        #expect(whole.map(\.identifierSet.count) == [450])

        let openEnded = SwiftMail.UIDSet(SwiftMail.UID(7)...)
        let open = try FetchHeaderFieldsCommand.chunks(
            fields: ["Received"], identifierSet: openEnded, chunkSize: 2, timeoutSeconds: nil
        )
        #expect(open.map(\.identifierSet.count) == [openEnded.count])
        #expect(open.first?.identifierSet.contains(SwiftMail.UID(7)) == true)
        #expect(open.first?.identifierSet.contains(SwiftMail.UID.latest) == true)

        #expect(throws: IMAPError.self) {
            try FetchHeaderFieldsCommand.chunks(
                fields: ["Received"], identifierSet: SwiftMail.UIDSet(), chunkSize: nil, timeoutSeconds: nil
            )
        }
        #expect(throws: IMAPError.self) {
            try FetchHeaderFieldsCommand(identifierSet: three, fields: ["Received"], timeoutSeconds: 0).validate()
        }
    }

    #if os(macOS)
        @Test("fetchHeaderFields sends one UID FETCH per chunk and merges the blocks")
        func fetchHeaderFieldsInChunks() async throws {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("cur"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("new"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            for number in 1...3 {
                let eml = "Received: from relay\(number).example.net\r\n\tby mx.example.org\r\n"
                    + "From: a@example.com\r\nReceived: from origin\(number).example.com\r\n"
                    + "Subject: Message \(number)\r\n\r\nHello\r\n"
                try Data(eml.utf8).write(to: maildir.appendingPathComponent("cur/\(number).eml"))
            }

            let testServer = try IMAPTestServer(maildirURL: maildir)
            try testServer.start()

            let blocks = try await testServer.run {
                let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()
                try await server.login(username: "testuser", password: "testpass")
                _ = try await server.selectMailbox("INBOX")
                let blocks = try await server.fetchHeaderFields(
                    ["Received"], using: SwiftMail.UIDSet(SwiftMail.UID(1)...SwiftMail.UID(3)),
                    chunkSize: 2, timeoutSeconds: 10
                )
                try await server.disconnect()
                return blocks
            }

            let expected = (1...3).map { number in
                Data(("Received: from relay\(number).example.net\r\n\tby mx.example.org\r\n"
                    + "Received: from origin\(number).example.com\r\n\r\n").utf8)
            }
            #expect(blocks == [
                SwiftMail.UID(1): expected[0], SwiftMail.UID(2): expected[1], SwiftMail.UID(3): expected[2]
            ])
            let fetches = testServer.commandLog.filter { $0.uppercased().contains("HEADER.FIELDS") }
            #expect(fetches.count == 2)
            #expect(fetches.first?.contains("UID FETCH 1:2 ") == true)
            #expect(fetches.last?.contains("UID FETCH 3 ") == true)
        }
    #endif
}
