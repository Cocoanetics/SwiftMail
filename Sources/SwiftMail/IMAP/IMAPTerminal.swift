import Foundation
import NIO

/// Shared by a connection's terminal cells and admission state. Locked transitions
/// return actions; user code, continuation resumes and NIO work run after unlocking.
final class IMAPLifetimeGate {
    typealias Action = () -> Void
    private let lock = NSLock()

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// The sole result authority for an operation. Producers complete this cell,
/// rather than independently completing promises made by its adapters.
final class IMAPTerminal<Value>: @unchecked Sendable {
    typealias Outcome = Result<Value, Error>
    let gate: IMAPLifetimeGate
    private var result: Outcome?
    private var observers: [(Outcome) -> Void] = []
    private var cleanups: [() -> Void] = []
    private var cleanupIDs: Set<UUID> = []

    init(gate: IMAPLifetimeGate = IMAPLifetimeGate()) {
        self.gate = gate
    }

    var isSettled: Bool { gate.withLock { !isPendingLocked } }

    /// Only read by coordinator transitions while the shared gate is held.
    var isPendingLocked: Bool { result == nil }

    @discardableResult
    func complete(_ result: Outcome) -> Bool {
        let actions = gate.withLock { settleLocked(result) }
        guard let actions else { return false }
        actions.forEach { $0() }
        return true
    }

    /// Called only with the shared gate held; nil means another producer won.
    func settleLocked(_ result: Outcome) -> [IMAPLifetimeGate.Action]? {
        guard self.result == nil else { return nil }
        self.result = result
        let deliveries = observers.map { observer in { observer(result) } }
        let actions = deliveries + cleanups
        observers.removeAll()
        cleanups.removeAll()
        return actions
    }

    func observe(_ observer: @escaping (Outcome) -> Void) {
        let ready = gate.withLock { () -> Outcome? in
            if let result { return result }
            observers.append(observer)
            return nil
        }
        if let ready { observer(ready) }
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            observe { continuation.resume(with: $0) }
        }
    }

    func future(on eventLoop: EventLoop) -> EventLoopFuture<Value> {
        let promise = eventLoop.makePromise(of: Value.self)
        observe { promise.completeWith($0) }
        return promise.futureResult
    }

    /// Reusing an ID attaches a resource at most once, even after settlement.
    /// Result delivery never waits for event-loop cleanup to finish.
    func addCleanup(id: UUID = UUID(), on eventLoop: EventLoop? = nil, _ cleanup: @escaping () -> Void) {
        let action: () -> Void = {
            if let eventLoop, !eventLoop.inEventLoop { eventLoop.execute(cleanup) } else { cleanup() }
        }
        let runNow = gate.withLock {
            guard cleanupIDs.insert(id).inserted else { return false }
            guard result == nil else { return true }
            cleanups.append(action)
            return false
        }
        if runNow { action() }
    }

    func attachTimer(_ timer: Scheduled<Void>, on eventLoop: EventLoop, id: UUID = UUID()) {
        addCleanup(id: id, on: eventLoop) { timer.cancel() }
    }

    /// Task.cancel can synchronously invoke foreign cancellation handlers. It
    /// must never delay terminal delivery, socket close, or the cancelling task.
    func attachTask<Success: Sendable, Failure: Error>(_ task: Task<Success, Failure>) {
        addCleanup { _ = Task.detached { task.cancel() } }
    }

    /// Successful late installation still gets removed when settlement wins
    /// during installation. Removal always runs on the captured event loop.
    func attachHandlerCleanup(
        after installation: EventLoopFuture<Void>,
        id: UUID = UUID(),
        remove: @escaping () -> Void
    ) {
        installation.whenComplete { result in
            switch result {
                case .success:
                    self.addCleanup(id: id, on: installation.eventLoop, remove)
                case .failure(let error):
                    self.complete(.failure(error))
            }
        }
    }
}
