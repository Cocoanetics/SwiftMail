//
//  IMAPCommandQueue.swift
//  SwiftMail
//
//  Created by Oliver Drobnik on 16.01.26.
//

import Foundation

private enum IMAPCommandQueueTaskContext {
    @TaskLocal static var ownerToken: UUID?
}

final class IMAPCommandQueue {
    private struct Waiter {
        let ownerToken: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var ownerToken: UUID?
    private var depth = 0
    private var waiters: [Waiter] = []

    func run<T>(_ op: () async throws -> T) async rethrows -> T {
        let token = IMAPCommandQueueTaskContext.ownerToken ?? UUID()

        return try await IMAPCommandQueueTaskContext.$ownerToken.withValue(token) {
            await acquire(ownerToken: token)
            defer { release(ownerToken: token) }
            return try await op()
        }
    }

    private func acquire(ownerToken: UUID) async {
        if acquireImmediatelyIfPossible(ownerToken: ownerToken) {
            return
        }

        await withCheckedContinuation { continuation in
            lock.lock()
            if ownerToken == self.ownerToken {
                depth += 1
                lock.unlock()
                continuation.resume()
                return
            }

            if self.ownerToken == nil {
                self.ownerToken = ownerToken
                depth = 1
                lock.unlock()
                continuation.resume()
                return
            }

            waiters.append(Waiter(ownerToken: ownerToken, continuation: continuation))
            lock.unlock()
        }
    }

    private func acquireImmediatelyIfPossible(ownerToken: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if ownerToken == self.ownerToken {
            depth += 1
            return true
        }

        if self.ownerToken == nil {
            self.ownerToken = ownerToken
            depth = 1
            return true
        }

        return false
    }

    private func release(ownerToken: UUID) {
        lock.lock()

        guard self.ownerToken == ownerToken else {
            lock.unlock()
            return
        }

        if depth > 1 {
            depth -= 1
            lock.unlock()
            return
        }

        guard !waiters.isEmpty else {
            self.ownerToken = nil
            depth = 0
            lock.unlock()
            return
        }

        let next = waiters.removeFirst()
        self.ownerToken = next.ownerToken
        depth = 1
        lock.unlock()

        next.continuation.resume()
    }
}
