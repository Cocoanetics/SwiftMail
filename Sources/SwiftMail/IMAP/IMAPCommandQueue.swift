//
//  IMAPCommandQueue.swift
//  SwiftMail
//
//  Created by Oliver Drobnik on 16.01.26.
//

import Foundation

final class IMAPCommandQueue {
    private struct Waiter {
        let ownerTask: UnsafeCurrentTask?
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var isOwned = false
    private var ownerTask: UnsafeCurrentTask?
    private var depth = 0
    private var waiters: [Waiter] = []

    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        let task = withUnsafeCurrentTask { $0 }
        await acquire(ownerTask: task)
        defer { release(ownerTask: task) }
        return try await operation()
    }

    private func acquire(ownerTask: UnsafeCurrentTask?) async {
        if acquireImmediatelyIfPossible(ownerTask: ownerTask) {
            return
        }

        await withCheckedContinuation { continuation in
            lock.lock()
            if isOwned && isSameTask(ownerTask, self.ownerTask) {
                depth += 1
                lock.unlock()
                continuation.resume()
                return
            }

            if !isOwned {
                isOwned = true
                self.ownerTask = ownerTask
                depth = 1
                lock.unlock()
                continuation.resume()
                return
            }

            waiters.append(Waiter(ownerTask: ownerTask, continuation: continuation))
            lock.unlock()
        }
    }

    private func acquireImmediatelyIfPossible(ownerTask: UnsafeCurrentTask?) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if isOwned && isSameTask(ownerTask, self.ownerTask) {
            depth += 1
            return true
        }

        if !isOwned {
            isOwned = true
            self.ownerTask = ownerTask
            depth = 1
            return true
        }

        return false
    }

    private func release(ownerTask: UnsafeCurrentTask?) {
        lock.lock()

        guard isOwned && isSameTask(self.ownerTask, ownerTask) else {
            lock.unlock()
            return
        }

        if depth > 1 {
            depth -= 1
            lock.unlock()
            return
        }

        guard !waiters.isEmpty else {
            isOwned = false
            self.ownerTask = nil
            depth = 0
            lock.unlock()
            return
        }

        let next = waiters.removeFirst()
        isOwned = true
        self.ownerTask = next.ownerTask
        depth = 1
        lock.unlock()

        next.continuation.resume()
    }

    private func isSameTask(_ lhs: UnsafeCurrentTask?, _ rhs: UnsafeCurrentTask?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs == rhs
    }
}
