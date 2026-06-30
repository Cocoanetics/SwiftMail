import Foundation
import Testing
@testable import SwiftMail

private actor EventRecorder {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPCommandQueueTests {
    @Test
    func testRunIsReentrantForNestedCallsOnSameTask() async throws {
        let queue = IMAPCommandQueue()
        let recorder = EventRecorder()

        await queue.run {
            await recorder.append("outer-start")

            await queue.run {
                await recorder.append("inner")
            }

            await recorder.append("outer-end")
        }

        let events = await recorder.snapshot()
        #expect(events == ["outer-start", "inner", "outer-end"])
    }

    @Test
    func testRunSerializesDifferentTasks() async throws {
        let queue = IMAPCommandQueue()
        let recorder = EventRecorder()

        let first = Task {
            try await queue.run {
                await recorder.append("first-start")
                try await Task.sleep(nanoseconds: 150_000_000)
                await recorder.append("first-end")
            }
        }

        try await Task.sleep(nanoseconds: 10_000_000)

        let second = Task {
            await queue.run {
                await recorder.append("second")
            }
        }

        try await first.value
        await second.value

        let events = await recorder.snapshot()
        #expect(events == ["first-start", "first-end", "second"])
    }

    @Test
    func testChildTaskDoesNotInheritQueueOwnership() async throws {
        let queue = IMAPCommandQueue()
        let recorder = EventRecorder()
        let childStarted = AsyncStream<Void>.makeStream()
        let childFinished = AsyncStream<Void>.makeStream()
        let releaseOuter = AsyncStream<Void>.makeStream()

        let outer = Task {
            await queue.run {
                await recorder.append("outer-start")

                Task {
                    childStarted.continuation.yield(())
                    await queue.run {
                        await recorder.append("child")
                    }
                    childFinished.continuation.yield(())
                    childFinished.continuation.finish()
                }

                var releaseIterator = releaseOuter.stream.makeAsyncIterator()
                await releaseIterator.next()
                await recorder.append("outer-end")
            }
        }

        var childIterator = childStarted.stream.makeAsyncIterator()
        await childIterator.next()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(await recorder.snapshot() == ["outer-start"])

        releaseOuter.continuation.yield(())
        releaseOuter.continuation.finish()
        await outer.value
        var childFinishedIterator = childFinished.stream.makeAsyncIterator()
        await childFinishedIterator.next()

        let events = await recorder.snapshot()
        #expect(events == ["outer-start", "outer-end", "child"])
    }
}
