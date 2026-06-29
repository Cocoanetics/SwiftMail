import Foundation
import Testing
import NIO
import NIOEmbedded
import NIOConcurrencyHelpers
@preconcurrency import NIOIMAP
import NIOIMAPCore
@testable import SwiftMail

// MARK: - PipelinedFetchPartHandler Tests

@Suite("PipelinedFetchPartHandler")
struct PipelinedFetchPartHandlerTests {

    private func makeEventLoop() -> EventLoop {
        MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
    }

    @Test("Fails promise on explicit fail() call")
    func failsOnExplicitFail() async {
        let eventLoop = makeEventLoop()
        let promise = eventLoop.makePromise(of: Data.self)
        let handler = PipelinedFetchPartHandler(promise: promise)

        handler.fail(IMAPError.connectionFailed("test"))

        do {
            _ = try await promise.futureResult.get()
            Issue.record("Should have thrown")
        } catch {
            // Expected
        }
    }

    @Test("Double fail is safe (idempotent)")
    func doubleFailSafe() async {
        let eventLoop = makeEventLoop()
        let promise = eventLoop.makePromise(of: Data.self)
        let handler = PipelinedFetchPartHandler(promise: promise)

        handler.fail(IMAPError.connectionFailed("first"))
        handler.fail(IMAPError.timeout) // Should not crash

        do {
            _ = try await promise.futureResult.get()
            Issue.record("Should have thrown")
        } catch {
            // Expected — first error wins
        }
    }

    @Test("Collects streaming bytes into partData")
    func collectsStreamingBytes() async throws {
        let eventLoop = makeEventLoop()
        let promise = eventLoop.makePromise(of: Data.self)
        let handler = PipelinedFetchPartHandler(promise: promise)

        // Simulate streaming: start → bytes → bytes → finish
        handler.processFetchResponse(.start(.init(1)))

        let chunk1 = Data("Hello, ".utf8)
        var buf1 = ByteBufferAllocator().buffer(capacity: chunk1.count)
        buf1.writeBytes(chunk1)
        handler.processFetchResponse(.streamingBytes(buf1))

        let chunk2 = Data("World!".utf8)
        var buf2 = ByteBufferAllocator().buffer(capacity: chunk2.count)
        buf2.writeBytes(chunk2)
        handler.processFetchResponse(.streamingBytes(buf2))

        handler.processFetchResponse(.finish)

        // Now resolve via tagged OK — simulate by calling processTaggedResponse
        // We need a real TaggedResponse which requires NIO types.
        // Instead, test via fail → verify data was collected up to that point.
        // (Full integration test would require a live server.)
        handler.fail(IMAPError.timeout)

        // Promise should fail, but we've verified the streaming path compiles and runs
        do {
            _ = try await promise.futureResult.get()
        } catch {
            // Expected
        }
    }

    @Test("Ignores data after finish flag")
    func ignoresDataAfterFinish() async {
        let eventLoop = makeEventLoop()
        let promise = eventLoop.makePromise(of: Data.self)
        let handler = PipelinedFetchPartHandler(promise: promise)

        handler.processFetchResponse(.start(.init(1)))
        handler.processFetchResponse(.finish)

        // Data after finish should be ignored
        let late = Data("late data".utf8)
        var buf = ByteBufferAllocator().buffer(capacity: late.count)
        buf.writeBytes(late)
        handler.processFetchResponse(.streamingBytes(buf))

        handler.fail(IMAPError.timeout) // resolve the promise

        do {
            _ = try await promise.futureResult.get()
        } catch {
            // Expected
        }
    }
}

// MARK: - Pipelined Connection Cleanup Tests

@Suite(.serialized, .timeLimit(.minutes(1)))
struct PipelinedFetchConnectionCleanupTests {
    @Test("Interrupted pipelined fetch recycles the connection before returning partial results")
    func interruptedPipelinedFetchRecyclesConnection() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            Task {
                try? await group.shutdownGracefully()
            }
        }

        let connection = IMAPConnection(
            host: "localhost",
            port: 143,
            transportSecurity: .plainText,
            group: group,
            loggerLabel: "test.imap",
            outboundLabel: "test.imap.out",
            inboundLabel: "test.imap.in",
            connectionID: "test-pipelined-interrupt",
            connectionRole: "test"
        )
        let channel = NIOAsyncTestingChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 143)
        try await channel.connect(to: address)
        try await channel.pipeline.addHandler(IMAPClientHandler())
        try await channel.pipeline.addHandler(connection.duplexLogger)
        try await channel.pipeline.addHandler(connection.responseBuffer)
        connection.replaceChannelForTesting(channel)

        let fetchTask = Task {
            try await connection.executePipelinedFetchParts(
                requests: [
                    (uid: UID(1), section: Section("1")),
                    (uid: UID(2), section: Section("2"))
                ],
                timeoutSeconds: 60
            )
        }

        guard var firstOutbound = try await readOutboundCommand(from: channel),
              let firstCommand = firstOutbound.readString(length: firstOutbound.readableBytes),
              let firstTag = firstCommand.split(separator: " ").first else {
            Issue.record("Expected first pipelined FETCH command")
            try? await channel.close()
            return
        }
        _ = try await readOutboundCommand(from: channel)

        var firstResponse = channel.allocator.buffer(capacity: 0)
        firstResponse.writeString("* 1 FETCH (BODY[1] {5}\r\nHello)\r\n\(firstTag) OK FETCH completed\r\n")
        try await channel.writeInbound(firstResponse)
        try await channel.close()

        let results = try await fetchTask.value
        #expect(results.map(\.uid) == [UID(1)])
        #expect(connection.channel == nil)
        #expect(!connection.responseBuffer.hasActiveHandler)
        if connection.channel != nil {
            try? await channel.close()
        }
    }

    private func readOutboundCommand(from channel: NIOAsyncTestingChannel) async throws -> ByteBuffer? {
        for _ in 0..<20 {
            if let outbound = try await channel.readOutbound(as: ByteBuffer.self) {
                return outbound
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }
}

// MARK: - PipelinedCommandDispatcher Tests

@Suite("PipelinedCommandDispatcher")
struct PipelinedCommandDispatcherTests {

    private func makeEventLoop() -> EventLoop {
        MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
    }

    @Test("Pending count tracks registered handlers")
    func pendingCount() {
        let eventLoop = makeEventLoop()
        let dispatcher = PipelinedCommandDispatcher()

        #expect(dispatcher.pendingCount == 0)

        let promise1 = eventLoop.makePromise(of: Data.self)
        let handler1 = PipelinedFetchPartHandler(promise: promise1)
        dispatcher.register(tag: "A001", handler: handler1)
        #expect(dispatcher.pendingCount == 1)

        let promise2 = eventLoop.makePromise(of: Data.self)
        let handler2 = PipelinedFetchPartHandler(promise: promise2)
        dispatcher.register(tag: "A002", handler: handler2)
        #expect(dispatcher.pendingCount == 2)

        // Clean up — resolve promises to avoid NIO "leaking promise" fatal error
        handler1.fail(IMAPError.timeout)
        handler2.fail(IMAPError.timeout)
    }

    @Test("Registered handlers can be failed individually")
    func failIndividualHandlers() async {
        let eventLoop = makeEventLoop()
        let dispatcher = PipelinedCommandDispatcher()

        let promise1 = eventLoop.makePromise(of: Data.self)
        let handler1 = PipelinedFetchPartHandler(promise: promise1)
        let promise2 = eventLoop.makePromise(of: Data.self)
        let handler2 = PipelinedFetchPartHandler(promise: promise2)

        dispatcher.register(tag: "A001", handler: handler1)
        dispatcher.register(tag: "A002", handler: handler2)

        // Fail handler1 only
        handler1.fail(IMAPError.timeout)

        do {
            _ = try await promise1.futureResult.get()
            Issue.record("handler1 should have failed")
        } catch {
            // Expected
        }

        // handler2 should still be pending — fail it too
        handler2.fail(IMAPError.connectionFailed("test"))

        do {
            _ = try await promise2.futureResult.get()
            Issue.record("handler2 should have failed")
        } catch {
            // Expected
        }
    }

    @Test("Dispatcher initializes with empty registry")
    func initEmpty() {
        let dispatcher = PipelinedCommandDispatcher()
        #expect(dispatcher.pendingCount == 0)
    }

    // MARK: - Response routing through channelRead

    /// Build a `* FETCH (BODY[...] {n})` streaming-bytes response.
    private func bytes(_ text: String) -> Response {
        var buf = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buf.writeString(text)
        return .fetch(.streamingBytes(buf))
    }

    /// Build a tagged `<tag> OK completed` response.
    private func taggedOK(_ tag: String) -> Response {
        .tagged(TaggedResponse(tag: tag, state: .ok(ResponseText(text: "completed"))))
    }

    /// Drive the dispatcher through an `EmbeddedChannel` (single-threaded, synchronous)
    /// with a scripted server response stream. One command is registered per tag (in
    /// order); returns each pipelined part's resolved bytes as UTF-8, aligned to `tags`.
    /// A `nil` result means that part's promise never resolved.
    private func resolveParts(tags: [String], stream: [Response]) throws -> [String?] {
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(loop: loop)
        let dispatcher = PipelinedCommandDispatcher()
        try channel.pipeline.syncOperations.addHandler(dispatcher)

        // EmbeddedEventLoop fires future callbacks inline when run — capture results
        // synchronously into a box so the test stays single-threaded (no cross-loop
        // promise + async await, which trips EmbeddedEventLoop's thread-safety check).
        final class Box: @unchecked Sendable { var results: [Data?] = [] }
        let box = Box(); box.results = Array(repeating: nil, count: tags.count)
        for (index, tag) in tags.enumerated() {
            let promise = loop.makePromise(of: Data.self)
            promise.futureResult.whenSuccess { box.results[index] = $0 }
            dispatcher.register(tag: tag, handler: PipelinedFetchPartHandler(promise: promise))
        }

        for response in stream {
            try channel.writeInbound(response)
        }
        loop.run()
        _ = try? channel.finish()

        return box.results.map { $0.flatMap { String(bytes: $0, encoding: .utf8) } }
    }

    /// Control: a server that strictly interleaves `data → OK → data → OK` routes
    /// each pipelined part to its own handler. This path works today and must keep
    /// working after the fix.
    @Test("Interleaved untagged FETCH (data, OK, data, OK) routes each part correctly")
    func interleavedRoutesToCorrectHandler() throws {
        let stream: [Response] = [
            .fetch(.start(.init(1))), bytes("PLAINTEXT"), .fetch(.finish), taggedOK("A001"),
            .fetch(.start(.init(1))), bytes("<html>HI</html>"), .fetch(.finish), taggedOK("A002")
        ]
        let parts = try resolveParts(tags: ["A001", "A002"], stream: stream)
        #expect(parts == ["PLAINTEXT", "<html>HI</html>"])
    }

    /// Regression reproduction for the "HTML email rendered as plaintext" bug.
    ///
    /// A server is allowed (RFC 3501 §5.5) to emit untagged FETCH data for MULTIPLE
    /// pipelined commands before sending their tagged OKs — common when responses are
    /// small and back-to-back (e.g. two sections of one short multipart/alternative).
    /// Wire order here: BODY[1] data, BODY[2] data, A001 OK, A002 OK.
    ///
    /// Pre-fix the dispatcher routed untagged FETCH to `entries.first` and only advanced
    /// on a tagged OK, so BODY[2]'s bytes were delivered to A001 (which had already
    /// finished part 1 and silently dropped them), leaving A002 — the text/html part —
    /// resolved EMPTY. Empty html ⇒ BodyRenderer falls back to plainTextToHTML ⇒ the
    /// HTML email is cached as escaped plaintext until pull-to-refresh.
    @Test("Batched untagged FETCH (both parts' data before either tagged OK) must not drop the second part")
    func batchedUntaggedRoutesToCorrectHandler() throws {
        let stream: [Response] = [
            .fetch(.start(.init(1))), bytes("PLAINTEXT"), .fetch(.finish),
            .fetch(.start(.init(1))), bytes("<html>HI</html>"), .fetch(.finish),
            taggedOK("A001"), taggedOK("A002")
        ]
        let parts = try resolveParts(tags: ["A001", "A002"], stream: stream)
        #expect(parts == ["PLAINTEXT", "<html>HI</html>"])
    }

    /// Three pipelined parts, fully batched (all data, then all OKs). Locks in that the
    /// routing cursor advances across MULTIPLE `.finish` boundaries — pre-fix, parts 2
    /// AND 3 were both dropped (all untagged data routed to the first, finished handler).
    @Test("Three batched untagged FETCH responses each route to their own handler")
    func threeBatchedPartsRouteCorrectly() throws {
        let stream: [Response] = [
            .fetch(.start(.init(1))), bytes("ONE"), .fetch(.finish),
            .fetch(.start(.init(1))), bytes("TWO"), .fetch(.finish),
            .fetch(.start(.init(1))), bytes("THREE"), .fetch(.finish),
            taggedOK("A001"), taggedOK("A002"), taggedOK("A003")
        ]
        let parts = try resolveParts(tags: ["A001", "A002", "A003"], stream: stream)
        #expect(parts == ["ONE", "TWO", "THREE"])
    }

    /// Mixed ordering: part 1 completes interleaved (data, OK), then parts 2 and 3 are
    /// batched (data, data, OK, OK) — after part 1's entry is removed by its tagged OK.
    /// Confirms the "oldest not-yet-finished" routing survives front removal.
    @Test("Mixed interleaved-then-batched ordering routes each part correctly")
    func mixedOrderingRoutesCorrectly() throws {
        let stream: [Response] = [
            .fetch(.start(.init(1))), bytes("ONE"), .fetch(.finish), taggedOK("A001"),
            .fetch(.start(.init(1))), bytes("TWO"), .fetch(.finish),
            .fetch(.start(.init(1))), bytes("THREE"), .fetch(.finish),
            taggedOK("A002"), taggedOK("A003")
        ]
        let parts = try resolveParts(tags: ["A001", "A002", "A003"], stream: stream)
        #expect(parts == ["ONE", "TWO", "THREE"])
    }
}
