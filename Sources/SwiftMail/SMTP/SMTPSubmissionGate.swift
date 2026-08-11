// SMTPSubmissionGate.swift
// Serializes complete SMTP mail transactions across actor reentrancy.

import Foundation
import NIOConcurrencyHelpers

/// A cancellation-aware FIFO gate used to keep SMTP mail transactions from
/// interleaving while `SMTPServer` is reentrant across network awaits.
final class SMTPSubmissionGate: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NIOLock()
    private var isHeld = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        let waiterID = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var acquiredImmediately = false
                var cancelledBeforeQueueing = false

                lock.withLock {
                    if Task.isCancelled {
                        cancelledBeforeQueueing = true
                    } else if isHeld {
                        waiters.append(Waiter(id: waiterID, continuation: continuation))
                    } else {
                        isHeld = true
                        acquiredImmediately = true
                    }
                }

                if cancelledBeforeQueueing {
                    continuation.resume(throwing: CancellationError())
                } else if acquiredImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.cancel(waiterID: waiterID)
        }

        // Cancellation can race with a waiter being granted. In that case the
        // cancellation callback no longer finds it in the queue, so release
        // the acquired permit before surfacing the cancellation.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        let nextContinuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard !waiters.isEmpty else {
                isHeld = false
                return nil
            }
            return waiters.removeFirst().continuation
        }
        nextContinuation?.resume()
    }

    private func cancel(waiterID: UUID) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
                return nil
            }
            return waiters.remove(at: index).continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}
