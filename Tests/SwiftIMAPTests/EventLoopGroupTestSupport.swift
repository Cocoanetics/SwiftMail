import Foundation
import NIO

/// Shuts `group` down deterministically **without** blocking a Swift Concurrency pool thread.
///
/// ## Why this is not just `try? group.syncShutdownGracefully()`
/// Because that call, made directly from a swift-testing test, blocks a cooperative-pool thread.
/// On a core-constrained CI runner it violates the pool's forward-progress guarantee and
/// deadlocks the entire run — the macOS job hangs until its `timeout-minutes: 10` fires and the
/// whole thing reports as *cancelled* rather than failed, which is a good deal harder to notice
/// than a red X.
///
/// This is not a new discovery: `IMAPResponseBufferLimitTests` documented and solved it in #179,
/// having watched a 7-minute hang. Dispatching the blocking call to a non-cooperative GCD queue
/// and awaiting the continuation keeps the shutdown deterministic without ever blocking the pool.
///
/// It lives here rather than being copied into each suite so the next test that needs an event
/// loop group finds the answer instead of the trap.
func shutDownGracefully(_ group: MultiThreadedEventLoopGroup) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            try? group.syncShutdownGracefully()
            continuation.resume()
        }
    }
}
