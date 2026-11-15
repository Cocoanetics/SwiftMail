import Foundation

/// A worker has its own operation authority. Every caller, including the caller
/// that starts it, owns only a cancellable subscription to its result.
final class SharedAttempt<Value>: @unchecked Sendable {
    let id = UUID()
    let token: OperationToken
    let terminal: IMAPTerminal<Value>
    private let lifetime: IMAPConnectionLifetime
    private var waiters: Set<UUID> = []

    var generation: ConnectionGeneration { token.generation }
    var waiterCount: Int { lifetime.gate.withLock { waiters.count } }

    init(lifetime: IMAPConnectionLifetime, parent: OperationToken?) {
        self.lifetime = lifetime
        (token, terminal) = lifetime.registerOperation(of: Value.self, parent: parent)
    }

    func start(
        on connection: IMAPConnection,
        operation: @escaping () async throws -> Value,
        completion: @escaping (Result<Value, Error>) async -> Void
    ) {
        let authority = [ObjectIdentifier(lifetime): token]
        let worker = Task.detached {
            await IMAPOperationScope.$tokens.withValue(authority) {
                do {
                    try connection.validateOperation()
                    let value = try await operation()
                    await completion(.success(value))
                } catch {
                    await completion(.failure(error))
                }
            }
        }
        terminal.addCleanup { worker.cancel() }
    }

    func value(parent: OperationToken?) async throws -> Value {
        let waiterID = UUID()
        let (_, waiter) = lifetime.registerOperation(of: Value.self, parent: parent)
        lifetime.gate.withLock { _ = waiters.insert(waiterID) }
        waiter.addCleanup { [weak self] in
            guard let self else { return }
            self.lifetime.gate.withLock { _ = self.waiters.remove(waiterID) }
        }
        // A cancelled waiter is not retained by an uncooperative worker.
        terminal.observe { [weak waiter] result in waiter?.complete(result) }
        return try await withTaskCancellationHandler {
            try await waiter.value()
        } onCancel: {
            waiter.complete(.failure(CancellationError()))
        }
    }

    /// Publish and settle under the same gate as abort. The owning actor checks
    /// the slot's attempt ID before calling this and before removing the slot.
    func complete(_ result: Result<Value, Error>, publish: () -> Void = {}) {
        let actions = lifetime.gate.withLock { () -> [IMAPLifetimeGate.Action] in
            guard terminal.isPendingLocked else { return [] }
            do {
                try lifetime.validateLocked(token)
                if case .success = result { publish() }
                return terminal.settleLocked(result) ?? []
            } catch {
                return terminal.settleLocked(.failure(error)) ?? []
            }
        }
        actions.forEach { $0() }
    }
}

extension IMAPConnection {
    /// Capture authority before authentication, without taking the command queue.
    /// Nested command entry points inherit this token through queue admission.
    func withOperationScope<Value>(_ body: @escaping () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if let token = operationToken {
            try lifetime.validate(token)
            return try await body()
        }
        let (token, terminal) = lifetime.registerOperation(of: Value.self)
        var authority = IMAPOperationScope.tokens
        authority[ObjectIdentifier(lifetime)] = token
        let ownerFinished = operationOwnerFinishedForTesting
        return try await withTaskCancellationHandler {
            let owner = Task { [self] in
                defer { ownerFinished?() }
                do {
                    let value = try await IMAPOperationScope.$tokens.withValue(authority) {
                        try lifetime.validate(token)
                        return try await body()
                    }
                    terminal.complete(.success(value))
                } catch {
                    terminal.complete(.failure(error))
                }
            }
            terminal.addCleanup { owner.cancel() }
            return try await terminal.value()
        } onCancel: {
            abortNow(cancelling: token)
        }
    }

    /// Foreign code receives only its closure and a result sink. Aborting the
    /// bridge wakes a queue owner even if the provider ignores cancellation.
    func resolveAccessToken(_ provider: @escaping @Sendable () async throws -> String) async throws -> String {
        try validateOperation()
        let (_, sink) = lifetime.registerOperation(of: String.self, parent: operationToken)
        let providerWorker = Task.detached {
            do { sink.complete(.success(try await provider())) } catch { sink.complete(.failure(error)) }
        }
        // Task.cancel() runs a provider's cancellation handler synchronously.
        // Keep foreign cleanup from delaying already-claimed terminal deliveries.
        sink.addCleanup { _ = Task.detached { providerWorker.cancel() } }
        let value = try await withTaskCancellationHandler {
            try await sink.value()
        } onCancel: {
            sink.complete(.failure(CancellationError()))
        }
        try validateOperation()
        return value
    }
}
