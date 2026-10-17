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

    @Test("The handler keeps each block up to its cap and none of the streamed bytes in its history")
    func handlerBoundsWhatItKeeps() throws {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: [SwiftMail.UID: Data].self)
        let handler = FetchHeaderFieldsHandler<SwiftMail.UID>(commandTag: "A1", promise: promise)
        let maximum = FetchHeaderFieldsHandler<SwiftMail.UID>.maximumHeaderBytes
        let oversized = maximum + 1000
        let chunk = ByteBuffer(repeating: UInt8(ascii: "x"), count: 4096)
        let section = SectionSpecifier(kind: .headerFields(["Received"]))

        _ = handler.processResponse(.fetch(.start(1)))
        _ = handler.processResponse(.fetch(.simpleAttribute(.uid(5))))
        _ = handler.processResponse(.fetch(.streamingBegin(kind: .body(section: section, offset: nil),
                                                           byteCount: oversized)))
        for _ in 0..<(oversized / chunk.readableBytes + 1) {
            _ = handler.processResponse(.fetch(.streamingBytes(chunk)))
        }
        _ = handler.processResponse(.fetch(.streamingEnd))
        _ = handler.processResponse(.fetch(.finish))
        #expect(handler.untaggedResponses.isEmpty)

        _ = handler.processResponse(.tagged(TaggedResponse(tag: "A1", state: .ok(ResponseText(text: "done")))))
        let blocks = try promise.futureResult.wait()
        #expect(blocks[SwiftMail.UID(5)]?.count == maximum)
    }

    // MARK: - Helpers

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
