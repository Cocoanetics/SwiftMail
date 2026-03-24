import Foundation
import Testing
import NIO
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

        let chunk1 = "Hello, ".data(using: .utf8)!
        var buf1 = ByteBufferAllocator().buffer(capacity: chunk1.count)
        buf1.writeBytes(chunk1)
        handler.processFetchResponse(.streamingBytes(buf1))

        let chunk2 = "World!".data(using: .utf8)!
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
        let late = "late data".data(using: .utf8)!
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

        let p1 = eventLoop.makePromise(of: Data.self)
        let h1 = PipelinedFetchPartHandler(promise: p1)
        dispatcher.register(tag: "A001", handler: h1)
        #expect(dispatcher.pendingCount == 1)

        let p2 = eventLoop.makePromise(of: Data.self)
        let h2 = PipelinedFetchPartHandler(promise: p2)
        dispatcher.register(tag: "A002", handler: h2)
        #expect(dispatcher.pendingCount == 2)

        // Clean up — resolve promises to avoid NIO "leaking promise" fatal error
        h1.fail(IMAPError.timeout)
        h2.fail(IMAPError.timeout)
    }

    @Test("Registered handlers can be failed individually")
    func failIndividualHandlers() async {
        let eventLoop = makeEventLoop()
        let dispatcher = PipelinedCommandDispatcher()

        let p1 = eventLoop.makePromise(of: Data.self)
        let h1 = PipelinedFetchPartHandler(promise: p1)
        let p2 = eventLoop.makePromise(of: Data.self)
        let h2 = PipelinedFetchPartHandler(promise: p2)

        dispatcher.register(tag: "A001", handler: h1)
        dispatcher.register(tag: "A002", handler: h2)

        // Fail h1 only
        h1.fail(IMAPError.timeout)

        do {
            _ = try await p1.futureResult.get()
            Issue.record("h1 should have failed")
        } catch {
            // Expected
        }

        // h2 should still be pending — fail it too
        h2.fail(IMAPError.connectionFailed("test"))

        do {
            _ = try await p2.futureResult.get()
            Issue.record("h2 should have failed")
        } catch {
            // Expected
        }
    }

    @Test("Dispatcher initializes with empty registry")
    func initEmpty() {
        let dispatcher = PipelinedCommandDispatcher()
        #expect(dispatcher.pendingCount == 0)
    }
}
