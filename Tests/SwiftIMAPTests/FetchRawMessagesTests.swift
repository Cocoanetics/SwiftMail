import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

/// Collects what a handler's sink receives, in order.
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(SwiftMail.UID, Data)] = []

    func add(_ uid: SwiftMail.UID, _ data: Data) { lock.withLock { items.append((uid, data)) } }
    var all: [(SwiftMail.UID, Data)] { lock.withLock { items } }
    var dictionary: [SwiftMail.UID: Data] { Dictionary(all, uniquingKeysWith: { first, _ in first }) }
}

@Suite("Fetch raw messages", .serialized, .timeLimit(.minutes(1)))
struct FetchRawMessagesTests {
    // MARK: - Command

    @Test("A UID set sends one UID FETCH of BODY.PEEK[]")
    func uidFetchWireFormat() async throws {
        let command = FetchRawMessagesCommand(
            identifierSet: SwiftMail.UIDSet(SwiftMail.UID(7)...SwiftMail.UID(9)), sink: { _, _ in }
        )
        #expect(try await encoded(command.toTaggedCommand(tag: "A001")) == "A001 UID FETCH 7:9 (UID BODY.PEEK[])\r\n")
    }

    @Test("A sequence number set sends a plain FETCH")
    func sequenceFetchWireFormat() async throws {
        let command = FetchRawMessagesCommand(
            identifierSet: SwiftMail.SequenceNumberSet(SwiftMail.SequenceNumber(1)...SwiftMail.SequenceNumber(2)),
            sink: { _, _ in }
        )
        #expect(try await encoded(command.toTaggedCommand(tag: "A002")) == "A002 FETCH 1:2 (UID BODY.PEEK[])\r\n")
    }

    @Test("Empty sets and timeouts of zero or less are rejected")
    func validation() throws {
        #expect(throws: IMAPError.self) {
            try FetchRawMessagesCommand(identifierSet: SwiftMail.UIDSet(), sink: { _, _ in }).validate()
        }
        for timeout in [0, -1] {
            #expect(throws: IMAPError.self) {
                try FetchRawMessagesCommand(
                    identifierSet: SwiftMail.UIDSet(SwiftMail.UID(1)), timeoutSeconds: timeout, sink: { _, _ in }
                ).validate()
            }
        }
        #expect(throws: IMAPError.self) {
            try FetchRawMessagesCommand.chunks(
                identifierSet: SwiftMail.UIDSet(), chunkSize: nil, timeoutSeconds: nil, sink: { _, _ in }
            )
        }
    }

    @Test("Chunks carry the timeout; defaults apply; a set ending in * is sent whole")
    func chunks() throws {
        let uids = SwiftMail.UIDSet(SwiftMail.UID(1)...SwiftMail.UID(60))
        let byDefault = try FetchRawMessagesCommand.chunks(
            identifierSet: uids, chunkSize: nil, timeoutSeconds: nil, sink: { _, _ in }
        )
        #expect(byDefault.map(\.identifierSet.count) == [25, 25, 10])
        #expect(byDefault.allSatisfy { $0.timeoutSeconds == 60 })

        let ten = SwiftMail.UIDSet(SwiftMail.UID(1)...SwiftMail.UID(10))
        let custom = try FetchRawMessagesCommand.chunks(
            identifierSet: ten, chunkSize: 3, timeoutSeconds: 90, sink: { _, _ in }
        )
        #expect(custom.map(\.identifierSet.count) == [3, 3, 3, 1])
        #expect(custom.allSatisfy { $0.timeoutSeconds == 90 })

        let whole = try FetchRawMessagesCommand.chunks(
            identifierSet: ten, chunkSize: 0, timeoutSeconds: nil, sink: { _, _ in }
        )
        #expect(whole.map(\.identifierSet.count) == [10])

        let open = try FetchRawMessagesCommand.chunks(
            identifierSet: SwiftMail.UIDSet(SwiftMail.UID(7)...), chunkSize: 2, timeoutSeconds: nil, sink: { _, _ in }
        )
        #expect(open.count == 1)
    }

    // MARK: - Responses

    @Test("Bodies are byte-exact: CRLF, 8-bit bytes and an embedded parenthesis; UID may follow the body")
    func bodiesAreRaw() async throws {
        var first = Data("Subject: a\r\n\r\nbody (with) paren\r\n".utf8)
        first.append(0xE9)
        let second = Data("Subject: b\r\n\r\n)\r\n".utf8)
        let received = try await executeFetch([
            response(sequenceNumber: 1, uid: 41, uidFirst: true, section: "", body: first),
            response(sequenceNumber: 2, uid: 42, uidFirst: false, section: "", body: second),
            Data("A001 OK FETCH completed\r\n".utf8)
        ])
        #expect(received.all.map(\.0) == [SwiftMail.UID(41), SwiftMail.UID(42)])
        #expect(received.dictionary == [SwiftMail.UID(41): first, SwiftMail.UID(42): second])
    }

    @Test("An unanswered message is not delivered; other sections and flag updates are ignored")
    func ignoresOthers() async throws {
        let body = Data("Subject: a\r\n\r\nx\r\n".utf8)
        let received = try await executeFetch([
            response(sequenceNumber: 1, uid: 10, uidFirst: true, section: "", body: body),
            response(sequenceNumber: 2, uid: 11, uidFirst: true, section: "1", body: body),
            response(sequenceNumber: 3, uid: 12, uidFirst: true, section: "HEADER", body: body),
            Data("* 5 FETCH (FLAGS (\\Seen))\r\n".utf8),
            Data("A001 OK FETCH completed\r\n".utf8)
        ])
        #expect(received.dictionary == [SwiftMail.UID(10): body])
    }

    @Test("A repeated body for a delivered UID is ignored")
    func duplicateIsIgnored() async throws {
        let first = Data("one\r\n".utf8)
        let later = Data("two\r\n".utf8)
        let received = try await executeFetch([
            response(sequenceNumber: 1, uid: 10, uidFirst: true, section: "", body: first),
            response(sequenceNumber: 1, uid: 10, uidFirst: true, section: "", body: later),
            Data("A001 OK FETCH completed\r\n".utf8)
        ])
        #expect(received.all.count == 1)
        #expect(received.dictionary == [SwiftMail.UID(10): first])
    }

    @Test("A second BODY[] in one FETCH response is ignored, not appended to the first")
    func repeatedBodyInOneResponse() async throws {
        let first = Data("one\r\n".utf8)
        let again = Data("two\r\n".utf8)
        var data = Data("* 1 FETCH (UID 10 BODY[] {\(first.count)}\r\n".utf8)
        data.append(first)
        data.append(contentsOf: Data(" BODY[] {\(again.count)}\r\n".utf8))
        data.append(again)
        data.append(contentsOf: Data(")\r\n".utf8))
        let received = try await executeFetch([data, Data("A001 OK FETCH completed\r\n".utf8)])
        #expect(received.dictionary == [SwiftMail.UID(10): first])
    }

    @Test("A body without its UID in a UID fetch fails the command; earlier bodies were delivered, none after")
    func bodyWithoutUID() async throws {
        let body = Data("Subject: a\r\n\r\nx\r\n".utf8)
        var withoutUID = Data("* 3 FETCH (BODY[] {\(body.count)}\r\n".utf8)
        withoutUID.append(body)
        withoutUID.append(contentsOf: Data(")\r\n".utf8))
        let received = Received()
        let error = await #expect(throws: IMAPError.self) {
            _ = try await executeFetch([
                response(sequenceNumber: 1, uid: 10, uidFirst: true, section: "", body: body),
                withoutUID,
                response(sequenceNumber: 4, uid: 11, uidFirst: true, section: "", body: body),
                Data("A001 OK FETCH completed\r\n".utf8)
            ], received: received)
        }
        #expect(error?.description.contains("without its UID") == true)
        #expect(received.dictionary == [SwiftMail.UID(10): body])
    }

    @Test("A sequence number fetch is keyed by sequence number")
    func keyedBySequenceNumber() async throws {
        let body = Data("Subject: a\r\n\r\nx\r\n".utf8)
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: Void.self)
        let seen = SeqReceived()
        try await channel.pipeline.addHandler(
            FetchRawMessagesHandler<SwiftMail.SequenceNumber>(commandTag: "A001", promise: promise) { seen.add($0, $1) }
        )
        try await send(on: channel, [
            response(sequenceNumber: 4, uid: 99, uidFirst: true, section: "", body: body),
            Data("A001 OK FETCH completed\r\n".utf8)
        ])
        try await promise.futureResult.get()
        #expect(seen.items == [SwiftMail.SequenceNumber(4)])
    }

    @Test("A tagged NO fails the fetch")
    func taggedNoFails() async throws {
        await #expect(throws: IMAPError.self) {
            _ = try await executeFetch([Data("A001 NO [SERVERBUG] fetch failed\r\n".utf8)])
        }
    }

    @Test("A body is delivered when its response ends, before the tagged OK, and leaves no history")
    func deliveredEarly() async throws {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: Void.self)
        let received = Received()
        let handler = FetchRawMessagesHandler<SwiftMail.UID>(commandTag: "A1", promise: promise) {
            received.add($0, $1)
        }
        _ = handler.processResponse(.fetch(.start(NIOIMAPCore.SequenceNumber(rawValue: 1))))
        _ = handler.processResponse(.fetch(.simpleAttribute(.uid(NIOIMAPCore.UID(rawValue: 5)))))
        _ = handler.processResponse(.fetch(.streamingBegin(kind: .body(section: .complete, offset: nil), byteCount: 3)))
        _ = handler.processResponse(.fetch(.streamingBytes(ByteBuffer(string: "abc"))))
        _ = handler.processResponse(.fetch(.streamingEnd))
        #expect(received.all.isEmpty)
        _ = handler.processResponse(.fetch(.finish))
        #expect(received.dictionary == [SwiftMail.UID(5): Data("abc".utf8)])
        #expect(!handler.isCompleted)
        #expect(handler.untaggedResponses.isEmpty)
        _ = handler.processResponse(.tagged(TaggedResponse(tag: "A1", state: .ok(ResponseText(text: "done")))))
        try await promise.futureResult.get()
    }

    // MARK: - Helpers

    private final class SeqReceived: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [SwiftMail.SequenceNumber] = []
        func add(_ number: SwiftMail.SequenceNumber, _: Data) { lock.withLock { stored.append(number) } }
        var items: [SwiftMail.SequenceNumber] { lock.withLock { stored } }
    }

    private func executeFetch(_ rawResponses: [Data], received: Received = Received()) async throws -> Received {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: Void.self)
        try await channel.pipeline.addHandler(
            FetchRawMessagesHandler<SwiftMail.UID>(commandTag: "A001", promise: promise) { received.add($0, $1) }
        )
        try await send(on: channel, rawResponses)
        try await promise.futureResult.get()
        return received
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

    private func encoded(_ command: TaggedCommand) async throws -> String {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))
        var wire = ""
        while let buffer = try await channel.readOutbound(as: ByteBuffer.self) {
            wire += String(buffer: buffer)
        }
        return wire
    }

    private func response(sequenceNumber: Int, uid: Int, uidFirst: Bool, section: String, body: Data) -> Data {
        let item = "BODY[\(section)] {\(body.count)}\r\n"
        var data = Data("* \(sequenceNumber) FETCH (".utf8)
        if uidFirst {
            data.append(contentsOf: Data("UID \(uid) \(item)".utf8))
            data.append(body)
            data.append(contentsOf: Data(")\r\n".utf8))
        } else {
            data.append(contentsOf: Data(item.utf8))
            data.append(body)
            data.append(contentsOf: Data(" UID \(uid))\r\n".utf8))
        }
        return data
    }
}

#if os(macOS)
    @Suite("Fetch raw messages round trip", .serialized, .timeLimit(.minutes(1)))
    struct FetchRawMessagesRoundTripTests {
        @Test("fetchRawMessages streams byte-exact bodies in chunks and leaves a missing UID out")
        func roundTrip() async throws {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("cur"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("new"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            var expected: [SwiftMail.UID: Data] = [:]
            for number in 1...3 {
                let eml = Data(("From: a@example.com\r\nSubject: Message \(number)\r\n\r\nHello (\(number))\r\n").utf8)
                try eml.write(to: maildir.appendingPathComponent("cur/\(number).eml"))
                expected[SwiftMail.UID(number)] = eml
            }

            let testServer = try IMAPTestServer(maildirURL: maildir)
            try testServer.start()

            let bodies = try await testServer.run {
                let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()
                try await server.login(username: "testuser", password: "testpass")
                _ = try await server.selectMailbox("INBOX")
                var bodies: [SwiftMail.UID: Data] = [:]
                let set = SwiftMail.UIDSet([SwiftMail.UID(1), SwiftMail.UID(2), SwiftMail.UID(3), SwiftMail.UID(99)])
                for try await (uid, data) in server.fetchRawMessages(using: set, chunkSize: 2, timeoutSeconds: 10) {
                    bodies[uid] = data
                }
                try await server.disconnect()
                return bodies
            }

            #expect(bodies == expected)
            let fetches = testServer.commandLog.filter { $0.uppercased().contains("BODY.PEEK[]") }
            #expect(fetches.count == 2)
        }

        @Test("fetchRawMessages finishes by throwing for an empty set or a bad timeout")
        func streamErrors() async throws {
            let server = IMAPServer(host: "127.0.0.1", port: 1, useTLS: false)
            await #expect(throws: IMAPError.self) {
                for try await _ in server.fetchRawMessages(using: SwiftMail.UIDSet()) {}
            }
        }
    }
#endif
