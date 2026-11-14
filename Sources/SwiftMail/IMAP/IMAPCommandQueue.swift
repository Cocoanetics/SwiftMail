//
//  IMAPCommandQueue.swift
//  SwiftMail
//
//  Created by Oliver Drobnik on 16.01.26.
//

final class IMAPCommandQueue {
    let lifetime: IMAPConnectionLifetime

    /// Test gates run outside the coordinator lock. Set before launching callers.
    struct TestHooks {
        var beforeEnqueue: (() async -> Void)?
        var didEnqueue: (() -> Void)?
        var beforeStart: (() async -> Void)?
    }
    var testHooks = TestHooks()

    init(lifetime: IMAPConnectionLifetime = IMAPConnectionLifetime()) {
        self.lifetime = lifetime
    }

    func run<T>(token: OperationToken? = nil, _ operation: () async throws -> T) async throws -> T {
        let task = withUnsafeCurrentTask { $0 }
        let reservation = try lifetime.makeReservation(token: token, task: task)
        defer { lifetime.release(reservation) }
        return try await withTaskCancellationHandler {
            // onCancel covers cancellation before registration; also handle entry
            // from a task that was already cancelled.
            if Task.isCancelled { lifetime.cancel(reservation) }
            return try await execute(reservation, operation)
        } onCancel: {
            lifetime.cancel(reservation)
        }
    }

    /// Teardown must wait its FIFO turn and run even when invoked from an
    /// already-cancelled task. The operation still executes in that task and
    /// may inspect cancellation itself; only queue admission ignores it.
    func runForCleanup<T>(token: OperationToken? = nil, _ operation: () async throws -> T) async throws -> T {
        let task = withUnsafeCurrentTask { $0 }
        let reservation = try lifetime.makeReservation(token: token, task: task)
        defer { lifetime.release(reservation) }
        return try await execute(reservation, operation)
    }

    private func execute<T>(
        _ reservation: IMAPConnectionLifetime.Reservation,
        _ operation: () async throws -> T
    ) async throws -> T {
        await testHooks.beforeEnqueue?()
        lifetime.enqueue(reservation)
        testHooks.didEnqueue?()
        _ = try await reservation.admission.value()
        await testHooks.beforeStart?()
        try lifetime.start(reservation)
        return try await operation()
    }
}
