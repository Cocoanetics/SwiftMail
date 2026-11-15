import Foundation
import NIO
import NIOEmbedded
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPTerminalTests {
    @Test(arguments: [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]])
    func completionTimeoutAndAbortHaveOneWinner(order: [Int]) async throws {
        let loop = EmbeddedEventLoop()
        let terminal = IMAPTerminal<Int>()
        let future = terminal.future(on: loop)
        let deliveries = IMAPTestCounter()
        let cleanups = IMAPTestCounter()
        let cleanupID = UUID()
        terminal.observe { _ in
            #expect(terminal.isSettled)
            _ = deliveries.increment()
        }
        let cleanup = {
            #expect(terminal.isSettled)
            _ = cleanups.increment()
        }
        terminal.addCleanup(id: cleanupID, cleanup)
        let outcomes: [Result<Int, Error>] = [
            .success(42), .failure(IMAPError.timeout), .failure(IMAPAbortReason.connectionAborted)
        ]
        for (index, outcome) in order.enumerated() {
            #expect(terminal.complete(outcomes[outcome]) == (index == 0))
        }
        terminal.addCleanup(id: cleanupID, cleanup)
        terminal.addCleanup { _ = cleanups.increment() }
        loop.run()
        switch order[0] {
            case 0:
                #expect(try await terminal.value() == 42)
                #expect(try await future.get() == 42)
            case 1:
                await #expect(throws: IMAPError.self) { try await terminal.value() }
                await #expect(throws: IMAPError.self) { try await future.get() }
            default:
                await #expect(throws: IMAPAbortReason.self) { try await terminal.value() }
                await #expect(throws: IMAPAbortReason.self) { try await future.get() }
        }
        #expect(deliveries.value == 1)
        #expect(cleanups.value == 2)
    }

    @Test
    func continuationRegisteredBeforeSettlementAlsoReceivesWinner() async throws {
        let terminal = IMAPTerminal<Int>()
        let observed = IMAPTestSignal()
        let bridge = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                terminal.observe { continuation.resume(with: $0) }
                observed.signal()
            }
        }
        await observed.wait()
        #expect(terminal.complete(.success(7)))
        #expect(!terminal.complete(.failure(IMAPError.timeout)))
        #expect(try await bridge.value == 7)
    }

    @Test(arguments: [false, true])
    func timersAttachedBeforeOrAfterSettlementAreCancelled(late: Bool) throws {
        let loop = EmbeddedEventLoop()
        let terminal = IMAPTerminal<Int>()
        let firings = IMAPTestCounter()
        let timer = loop.scheduleTask(in: .seconds(5)) { _ = firings.increment() }
        if late { terminal.complete(.success(42)) }
        terminal.attachTimer(timer, on: loop)
        if !late { terminal.complete(.success(42)) }
        loop.run()
        loop.advanceTime(by: .seconds(6))
        #expect(firings.value == 0)
    }

    @Test(arguments: [false, true])
    func lateHandlerInstallationIsRemovedOnce(installationFirst: Bool) throws {
        let channel = EmbeddedChannel()
        let terminal = IMAPTerminal<Int>()
        let installation = channel.eventLoop.makePromise(of: Void.self)
        let removals = IMAPTestCounter()
        let cleanupID = UUID()
        let handler = TerminalProbeHandler(removals: removals)
        let remove = {
            channel.eventLoop.preconditionInEventLoop()
            #expect(terminal.isSettled)
            channel.pipeline.removeHandler(handler).whenFailure { Issue.record($0) }
        }
        terminal.attachHandlerCleanup(after: installation.futureResult, id: cleanupID, remove: remove)
        terminal.attachHandlerCleanup(after: installation.futureResult, id: cleanupID, remove: remove)
        if installationFirst {
            try channel.pipeline.addHandler(handler).wait()
            installation.succeed(())
        }
        terminal.complete(.failure(IMAPAbortReason.connectionAborted))
        // Settlement does not wait for the outstanding installation promise.
        let result = terminal.future(on: channel.eventLoop)
        #expect(throws: IMAPAbortReason.self) { try result.wait() }
        if !installationFirst {
            #expect(removals.value == 0)
            try channel.pipeline.addHandler(handler).wait()
            installation.succeed(())
        }
        channel.embeddedEventLoop.run()
        #expect(removals.value == 1)
        _ = try channel.finish()
    }

    @Test
    func handlerAndTimerCompleteThroughTheSameGate() throws {
        let channel = EmbeddedChannel()
        let terminal = IMAPTerminal<Int>()
        let removals = IMAPTestCounter()
        let handler = TerminalProbeHandler(removals: removals, terminal: terminal)
        let future = terminal.future(on: channel.eventLoop)
        let installation = channel.pipeline.addHandler(handler)
        terminal.attachHandlerCleanup(after: installation) {
            channel.pipeline.removeHandler(handler).whenFailure { Issue.record($0) }
        }
        let timer = channel.eventLoop.scheduleTask(in: .seconds(5)) {
            _ = terminal.complete(.failure(IMAPError.timeout))
        }
        terminal.attachTimer(timer, on: channel.eventLoop)
        try channel.writeInbound(channel.allocator.buffer(capacity: 0))
        channel.embeddedEventLoop.run()
        channel.embeddedEventLoop.advanceTime(by: .seconds(6))
        #expect(try future.wait() == 42)
        #expect(!terminal.complete(.failure(IMAPAbortReason.connectionAborted)))
        #expect(removals.value == 1)
        _ = try channel.finish()
    }

    @Test(arguments: [false, true])
    func installationFailureUsesTheTerminalGate(completionFirst: Bool) throws {
        let loop = EmbeddedEventLoop()
        let terminal = IMAPTerminal<Int>()
        let installation = loop.makePromise(of: Void.self)
        let future = terminal.future(on: loop)
        terminal.attachHandlerCleanup(after: installation.futureResult) {
            Issue.record("Failed installation has nothing to remove")
        }
        if completionFirst { terminal.complete(.success(42)) }
        installation.fail(IMAPConcurrencyTestError.expected)
        loop.run()
        if completionFirst {
            #expect(try future.wait() == 42)
        } else {
            #expect(throws: IMAPConcurrencyTestError.self) { try future.wait() }
        }
    }

    @Test
    func settlementDoesNotWaitForCapturedEventLoopCleanup() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let blocked = IMAPTestSignal()
        let release = DispatchSemaphore(value: 0)
        let cleaned = IMAPTestSignal()
        let terminal = IMAPTerminal<Int>()
        loop.execute {
            blocked.signal()
            release.wait()
        }
        await blocked.wait()
        terminal.addCleanup(on: loop) {
            loop.preconditionInEventLoop()
            #expect(terminal.isSettled)
            cleaned.signal()
        }
        terminal.complete(.success(42))
        #expect(try await terminal.value() == 42)
        release.signal()
        await cleaned.wait()
        try await group.shutdownGracefully()
    }
}

private final class TerminalProbeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    let removals: IMAPTestCounter
    let terminal: IMAPTerminal<Int>?

    init(removals: IMAPTestCounter, terminal: IMAPTerminal<Int>? = nil) {
        self.removals = removals
        self.terminal = terminal
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        terminal?.complete(.success(42))
    }

    func handlerRemoved(context: ChannelHandlerContext) { _ = removals.increment() }
}
