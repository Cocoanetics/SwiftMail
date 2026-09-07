import Foundation
import NIO

/// Shuts `group` down deterministically without parking **any** thread on the result.
///
/// ## Why this is not `try? group.syncShutdownGracefully()`
/// That call parks the calling thread on a semaphore whose signal is delivered via the
/// default-QoS global queue. Called from a swift-testing test it parks a cooperative-pool
/// thread; the pool is one thread per core, and the same threads back the default-QoS global
/// queue — so on a core-constrained CI runner a handful of concurrent shutdowns consume every
/// thread that could have delivered their wake-ups, and the whole run deadlocks until the job
/// timeout reports it as *cancelled*. Moving the blocking call onto a GCD queue (this helper's
/// first iteration, after #179 hit the 7-minute variant of the same hang) only relocates the
/// parked thread into the very pool that has to deliver the signal.
///
/// The callback form initiates the identical shutdown and resumes the continuation from NIO's
/// completion callback directly: deterministic completion, zero threads parked anywhere.
///
/// It lives here rather than being copied into each suite so the next test that needs an event
/// loop group finds the answer instead of the trap.
func shutDownGracefully(_ group: MultiThreadedEventLoopGroup) async {
    await withCheckedContinuation { continuation in
        group.shutdownGracefully { _ in
            continuation.resume()
        }
    }
}

/// Runs `body` with a fresh group and shuts that group down on every exit path.
///
/// A trailing `await shutDownGracefully(group)` is skipped whenever the body throws or
/// returns early, leaving the group running for the rest of the test run; `defer` cannot
/// hold the call because the shutdown is async. This wrapper is the only shape that
/// covers the success, early-return and throwing paths alike.
func withEventLoopGroup(
    numberOfThreads: Int = 1,
    _ body: (MultiThreadedEventLoopGroup) async throws -> Void
) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: numberOfThreads)

    do {
        try await body(group)
        await shutDownGracefully(group)
    } catch {
        await shutDownGracefully(group)
        throw error
    }
}
