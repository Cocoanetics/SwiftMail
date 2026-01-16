//
//  IMAPCommandQueue.swift
//  SwiftMail
//
//  Created by Oliver Drobnik on 16.01.26.
//


final class IMAPCommandQueue {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ op: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await op()
    }

    private func acquire() async {
        if !isRunning {
            isRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isRunning = false
            return
        }

        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}
