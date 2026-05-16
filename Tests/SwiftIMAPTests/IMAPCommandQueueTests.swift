import Foundation
@testable import SwiftMail
import Testing

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
    func runIsReentrantForNestedCallsOnSameTask() async {
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
    func runSerializesDifferentTasks() async throws {
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
}
