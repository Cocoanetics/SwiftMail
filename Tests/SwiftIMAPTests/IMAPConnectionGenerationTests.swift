import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPConnectionGenerationTests {
    @Test
    func invalidationSettlesOperationsAndWaitersBeforeOldOwnerReturns() async throws {
        let lifetime = IMAPConnectionLifetime()
        let queue = IMAPCommandQueue(lifetime: lifetime)
        let (oldToken, oldTerminal) = lifetime.registerOperation(of: Int.self)
        let oldGeneration = lifetime.currentGeneration
        let ownerStarted = IMAPTestSignal()
        let releaseOldOwner = IMAPTestSignal()
        let enqueued = AsyncStream<Void>.makeStream()
        queue.testHooks.didEnqueue = { enqueued.continuation.yield(()) }
        var iterator = enqueued.stream.makeAsyncIterator()
        let oldOwner = Task {
            try await queue.run(token: oldToken) {
                ownerStarted.signal()
                await releaseOldOwner.wait()
                oldTerminal.complete(.success(99))
            }
        }
        await ownerStarted.wait()
        await iterator.next()
        var waiters: [Task<Void, Error>] = []
        for _ in 0..<3 {
            waiters.append(Task {
                try await queue.run(token: oldToken) { _ = Issue.record("Old waiter ran") }
            })
            await iterator.next()
        }

        lifetime.invalidate()
        lifetime.invalidate()
        await #expect(throws: IMAPAbortReason.connectionAborted) { try await oldTerminal.value() }
        for waiter in waiters {
            await #expect(throws: IMAPAbortReason.connectionAborted) { try await waiter.value }
        }
        #expect(lifetime.reservationCount == 0)
        await #expect(throws: IMAPAbortReason.connectionAborted) { try await queue.run(token: oldToken) {} }
        await #expect(throws: IMAPAbortReason.connectionAborted) { try await queue.run {} }
        let (_, rejected) = lifetime.registerOperation(of: Int.self)
        await #expect(throws: IMAPAbortReason.connectionAborted) { try await rejected.value() }

        let freshGeneration = lifetime.rearm()
        #expect(freshGeneration != oldGeneration)
        #expect(lifetime.rearm() == freshGeneration)
        #expect(throws: IMAPAbortReason.connectionAborted) { try lifetime.validate(oldToken) }
        await #expect(throws: IMAPAbortReason.connectionAborted) { try await queue.run(token: oldToken) {} }
        try await verifyFreshQueue(queue, iterator: &iterator) {
            releaseOldOwner.signal()
            try await oldOwner.value
        }
    }

    private func verifyFreshQueue(
        _ queue: IMAPCommandQueue,
        iterator: inout AsyncStream<Void>.Iterator,
        staleRelease: () async throws -> Void
    ) async throws {
        let lifetime = queue.lifetime
        let (freshToken, freshTerminal) = lifetime.registerOperation(of: Int.self)
        let freshStarted = IMAPTestSignal()
        let releaseFreshOwner = IMAPTestSignal()
        let freshOwner = Task {
            try await queue.run(token: freshToken) {
                freshStarted.signal()
                await releaseFreshOwner.wait()
                freshTerminal.complete(.success(42))
            }
        }
        await freshStarted.wait()
        await iterator.next()
        let followerCalls = IMAPTestCounter()
        let follower = Task { try await queue.run { followerCalls.increment() } }
        await iterator.next()

        // The old owner's defer must neither release the fresh owner nor grant
        // its follower, even though both belong to the same coordinator object.
        try await staleRelease()
        #expect(followerCalls.value == 0)
        #expect(lifetime.reservationCount == 2)
        #expect(!freshTerminal.isSettled)
        releaseFreshOwner.signal()
        try await freshOwner.value
        #expect(try await freshTerminal.value() == 42)
        #expect(try await follower.value == 1)
        #expect(lifetime.reservationCount == 0)
    }

    @Test
    func completionAndInvalidationHaveOneSharedWinner() async throws {
        for abortFirst in [true, false] {
            let lifetime = IMAPConnectionLifetime()
            let (token, terminal) = lifetime.registerOperation(of: Int.self)
            let deliveries = IMAPTestCounter()
            let cleanups = IMAPTestCounter()
            terminal.observe { _ in
                _ = deliveries.increment()
                // Reentering the coordinator would deadlock under its gate.
                _ = lifetime.currentGeneration
                // Completion revokes the token before callbacks, even before
                // the registration's cleanup has had a chance to remove it.
                #expect(throws: IMAPAbortReason.self) { try lifetime.validate(token) }
            }
            terminal.addCleanup { _ = cleanups.increment() }
            if abortFirst {
                lifetime.invalidate()
                #expect(!terminal.complete(.success(42)))
                await #expect(throws: IMAPAbortReason.connectionAborted) { try await terminal.value() }
            } else {
                #expect(terminal.complete(.success(42)))
                lifetime.invalidate()
                #expect(try await terminal.value() == 42)
            }
            #expect(deliveries.value == 1)
            #expect(cleanups.value == 1)
            #expect(throws: IMAPAbortReason.self) { try lifetime.validate(token) }
        }
    }

    @Test
    func invalidationBeforeEnqueueAndAfterGrantPreventsStart() async throws {
        for enqueueFirst in [false, true] {
            let lifetime = IMAPConnectionLifetime()
            let reservation = try lifetime.makeReservation(token: nil, task: nil)
            if enqueueFirst { lifetime.enqueue(reservation) }
            lifetime.invalidate()
            lifetime.rearm()
            lifetime.enqueue(reservation)
            #expect(throws: IMAPAbortReason.self) { try lifetime.start(reservation) }
            lifetime.release(reservation)
            #expect(lifetime.reservationCount == 0)
        }
    }
}
