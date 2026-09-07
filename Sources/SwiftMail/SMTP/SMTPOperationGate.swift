// SMTPOperationGate.swift
// Serializes complete SMTP operations across actor reentrancy.

import Foundation
import NIOConcurrencyHelpers

/// A cancellation-aware FIFO gate used to keep all operations on one SMTP
/// channel from interleaving while `SMTPServer` is reentrant across awaits.
final class SMTPOperationGate: @unchecked Sendable {
    struct Permit: Sendable {
        fileprivate let id: UUID
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Permit, Error>
    }

    private let lock = NIOLock()
    private var currentPermitID: UUID?
    private var waiters: [Waiter] = []
    private var queuedWaiterObservers: [CheckedContinuation<Void, Never>] = []

    func acquire() async throws -> Permit {
        try Task.checkCancellation()
        let waiterID = UUID()

        let permit = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var acquiredImmediately = false
                var cancelledBeforeQueueing = false
                var observersToResume: [CheckedContinuation<Void, Never>] = []

                lock.withLock {
                    if Task.isCancelled {
                        cancelledBeforeQueueing = true
                    } else if currentPermitID != nil {
                        waiters.append(Waiter(id: waiterID, continuation: continuation))
                        observersToResume = queuedWaiterObservers
                        queuedWaiterObservers.removeAll()
                    } else {
                        currentPermitID = waiterID
                        acquiredImmediately = true
                    }
                }

                for observer in observersToResume {
                    observer.resume()
                }

                if cancelledBeforeQueueing {
                    continuation.resume(throwing: CancellationError())
                } else if acquiredImmediately {
                    continuation.resume(returning: Permit(id: waiterID))
                }
            }
        } onCancel: {
            self.cancel(waiterID: waiterID)
        }

        // Cancellation can race with a waiter being granted. In that case the
        // cancellation callback no longer finds it in the queue, so release
        // the acquired permit before surfacing the cancellation.
        if Task.isCancelled {
            release(permit)
            throw CancellationError()
        }
        return permit
    }

    func release(_ permit: Permit) {
        var releasedCurrentPermit = false
        let nextWaiter: Waiter? = lock.withLock {
            guard currentPermitID == permit.id else {
                return nil
            }
            releasedCurrentPermit = true
            guard !waiters.isEmpty else {
                currentPermitID = nil
                return nil
            }
            let waiter = waiters.removeFirst()
            currentPermitID = waiter.id
            return waiter
        }
        precondition(releasedCurrentPermit, "Attempted to release an SMTP operation permit that is not held")
        if let nextWaiter {
            nextWaiter.continuation.resume(returning: Permit(id: nextWaiter.id))
        }
    }

    func isHeld(_ permit: Permit) -> Bool {
        lock.withLock { currentPermitID == permit.id }
    }

    /// Test support for proving that a second operation has reached this gate
    /// while another operation still owns the channel. This avoids treating a
    /// scheduler-dependent sleep as evidence that serialization is working.
    func waitUntilOperationQueuedForTesting() async {
        await withCheckedContinuation { continuation in
            var shouldResumeImmediately = false
            lock.withLock {
                if waiters.isEmpty {
                    queuedWaiterObservers.append(continuation)
                } else {
                    shouldResumeImmediately = true
                }
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }

    private func cancel(waiterID: UUID) {
        let continuation: CheckedContinuation<Permit, Error>? = lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
                return nil
            }
            return waiters.remove(at: index).continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}
