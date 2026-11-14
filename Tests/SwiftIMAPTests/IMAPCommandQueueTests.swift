import Foundation
import Testing
@testable import SwiftMail

private actor EventRecorder {
    private var events: [Int] = []
    func append(_ event: Int) { events.append(event) }
    func snapshot() -> [Int] { events }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPCommandQueueTests {
    @Test(arguments: [0, 1, 3])
    func fifoSurvivesCancelledHeadMiddleAndTail(cancelled: Int) async throws {
        let queue = IMAPCommandQueue()
        let recorder = EventRecorder()
        let enqueued = AsyncStream<Void>.makeStream()
        queue.testHooks.didEnqueue = { enqueued.continuation.yield(()) }
        var iterator = enqueued.stream.makeAsyncIterator()
        let started = IMAPTestSignal()
        let release = IMAPTestSignal()
        let owner = Task {
            try await queue.run {
                started.signal()
                await release.wait()
            }
        }
        await started.wait()
        await iterator.next()
        var callers: [Task<Void, Error>] = []
        for index in 0..<4 {
            callers.append(Task { try await queue.run { await recorder.append(index) } })
            await iterator.next()
        }

        callers[cancelled].cancel()
        await #expect(throws: CancellationError.self) { try await callers[cancelled].value }
        #expect(await recorder.snapshot().isEmpty)
        #expect(queue.lifetime.reservationCount == 4)
        release.signal()
        try await owner.value
        for index in 0..<4 where index != cancelled { try await callers[index].value }
        #expect(await recorder.snapshot() == (0..<4).filter { $0 != cancelled })
        #expect(queue.lifetime.reservationCount == 0)
    }

    @Test
    func alreadyCancelledAdmissionNeverExecutes() async throws {
        let queue = IMAPCommandQueue()
        let ownerStarted = IMAPTestSignal()
        let releaseOwner = IMAPTestSignal()
        let owner = Task {
            try await queue.run {
                ownerStarted.signal()
                await releaseOwner.wait()
            }
        }
        await ownerStarted.wait()
        let enter = IMAPTestSignal()
        let caller = Task {
            await enter.wait()
            try await queue.run { _ = Issue.record("Cancelled closure ran") }
        }
        caller.cancel()
        enter.signal()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(queue.lifetime.reservationCount == 1)
        releaseOwner.signal()
        try await owner.value
        #expect(try await queue.run { 42 } == 42)
        #expect(queue.lifetime.reservationCount == 0)
    }

    @Test
    func cancellationBeforeEnqueueAndContinuationRegistration() async throws {
        let queue = IMAPCommandQueue()
        let created = IMAPTestSignal()
        let enqueue = IMAPTestSignal()
        queue.testHooks.beforeEnqueue = {
            created.signal()
            await enqueue.wait()
        }
        let caller = Task { try await queue.run { _ = Issue.record("Cancelled closure ran") } }
        await created.wait()
        caller.cancel()
        #expect(queue.lifetime.reservationCount == 0)
        enqueue.signal()
        await #expect(throws: CancellationError.self) { try await caller.value }
    }

    @Test
    func cancellationAfterGrantBeforeStartRetiresReservation() async throws {
        let queue = IMAPCommandQueue()
        let starts = IMAPTestCounter()
        let granted = IMAPTestSignal()
        let start = IMAPTestSignal()
        let ownerStarted = IMAPTestSignal()
        let releaseOwner = IMAPTestSignal()
        let queued = IMAPTestSignal()
        let enqueues = IMAPTestCounter()
        queue.testHooks.didEnqueue = { if enqueues.increment() == 2 { queued.signal() } }
        queue.testHooks.beforeStart = {
            if starts.increment() == 2 {
                granted.signal()
                await start.wait()
            }
        }
        let owner = Task {
            try await queue.run {
                ownerStarted.signal()
                await releaseOwner.wait()
            }
        }
        await ownerStarted.wait()
        let caller = Task { try await queue.run { _ = Issue.record("Cancelled granted closure ran") } }
        await queued.wait()
        releaseOwner.signal()
        try await owner.value
        await granted.wait()
        caller.cancel()

        // Fresh work proceeds even while the cancelled grantee has not unwound.
        #expect(try await queue.run { 42 } == 42)
        #expect(queue.lifetime.reservationCount == 0)
        start.signal()
        await #expect(throws: CancellationError.self) { try await caller.value }
    }

    @Test
    func cancellationAfterStartLeavesActivePolicyToCaller() async throws {
        let queue = IMAPCommandQueue()
        let entered = IMAPTestSignal()
        let release = IMAPTestSignal()
        let queued = IMAPTestSignal()
        let enqueues = IMAPTestCounter()
        queue.testHooks.didEnqueue = { if enqueues.increment() == 2 { queued.signal() } }
        let invocations = IMAPTestCounter()
        let owner = Task {
            try await queue.run {
                _ = invocations.increment()
                entered.signal()
                await release.wait()
                return 7
            }
        }
        await entered.wait()
        owner.cancel()
        let follower = Task { try await queue.run { invocations.increment() } }
        await queued.wait()
        #expect(invocations.value == 1)
        #expect(queue.lifetime.reservationCount == 2)
        release.signal()
        #expect(try await owner.value == 7)
        #expect(try await follower.value == 2)
        #expect(queue.lifetime.reservationCount == 0)
    }

    @Test
    func nestedDepthAcrossSuspensionAndError() async throws {
        let queue = IMAPCommandQueue()
        let innerStarted = IMAPTestSignal()
        let releaseInner = IMAPTestSignal()
        let outerResumed = IMAPTestSignal()
        let releaseOuter = IMAPTestSignal()
        let followerQueued = IMAPTestSignal()
        let enqueues = IMAPTestCounter()
        queue.testHooks.didEnqueue = { if enqueues.increment() == 3 { followerQueued.signal() } }
        let invocations = IMAPTestCounter()
        let owner = Task {
            try await queue.run {
                do {
                    try await queue.run {
                        innerStarted.signal()
                        await releaseInner.wait()
                        try await queue.run { throw IMAPConcurrencyTestError.expected }
                    }
                } catch IMAPConcurrencyTestError.expected {}
                outerResumed.signal()
                await releaseOuter.wait()
            }
        }
        await innerStarted.wait()
        let follower = Task { try await queue.run { invocations.increment() } }
        await followerQueued.wait()
        #expect(queue.lifetime.reservationCount == 3)
        releaseInner.signal()
        await outerResumed.wait()
        #expect(invocations.value == 0)
        #expect(queue.lifetime.reservationCount == 2)
        releaseOuter.signal()
        try await owner.value
        #expect(try await follower.value == 1)
        #expect(queue.lifetime.reservationCount == 0)
    }

    @Test(arguments: [false, true])
    func childTasksHaveIndependentOwnership(detached: Bool) async throws {
        let queue = IMAPCommandQueue()
        let recorder = EventRecorder()
        let childHandle = IMAPTerminal<Task<Void, Error>>()
        let releaseOuter = IMAPTestSignal()
        let childQueued = IMAPTestSignal()
        let enqueues = IMAPTestCounter()
        queue.testHooks.didEnqueue = { if enqueues.increment() == 2 { childQueued.signal() } }
        let outer = Task {
            try await queue.run {
                await recorder.append(0)
                let operation = { try await queue.run { await recorder.append(2) } }
                let child = detached ? Task.detached(operation: operation) : Task(operation: operation)
                childHandle.complete(.success(child))
                await releaseOuter.wait()
                await recorder.append(1)
            }
        }
        let child = try await childHandle.value()
        await childQueued.wait()
        #expect(await recorder.snapshot() == [0])
        releaseOuter.signal()
        try await outer.value
        try await child.value
        #expect(await recorder.snapshot() == [0, 1, 2])
    }

    @Test
    func asyncLetHasIndependentOwnership() async throws {
        let queue = IMAPCommandQueue()
        let childQueued = IMAPTestSignal()
        let enqueues = IMAPTestCounter()
        queue.testHooks.didEnqueue = { if enqueues.increment() == 2 { childQueued.signal() } }
        await #expect(throws: IMAPConcurrencyTestError.self) {
            try await queue.run {
                async let _: Void = queue.run { _ = Issue.record("Child inherited ownership") }
                await childQueued.wait()
                #expect(queue.lifetime.reservationCount == 2)
                // Leaving this scope cancels the queued async-let child.
                throw IMAPConcurrencyTestError.expected
            }
        }
        #expect(queue.lifetime.reservationCount == 0)
    }

    @Test
    func nilTaskIdentityCannotEstablishReentrancy() async throws {
        let lifetime = IMAPConnectionLifetime()
        let first = try lifetime.makeReservation(token: nil, task: nil)
        let second = try lifetime.makeReservation(token: nil, task: nil)
        lifetime.enqueue(first)
        lifetime.enqueue(second)
        #expect(first.admission.isSettled)
        #expect(!second.admission.isSettled)
        lifetime.release(first)
        #expect(second.admission.isSettled)
        try lifetime.start(second)
        lifetime.release(second)
        #expect(lifetime.reservationCount == 0)
    }
}
