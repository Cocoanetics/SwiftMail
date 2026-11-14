import Foundation

struct ConnectionGeneration: Hashable {
    fileprivate let id = UUID()
}

struct OperationToken: Hashable {
    let generation: ConnectionGeneration
    fileprivate let id = UUID()
}

struct QueueLease: Hashable {
    let generation: ConnectionGeneration
    fileprivate let id = UUID()
}

/// The public cancellation slice can map this internal reason to its public error.
enum IMAPAbortReason: Error, Equatable {
    case connectionAborted
}

/// Generation identity deliberately says nothing about the current transport.
/// Peer-loss recovery need not rearm; only an explicit post-abort request does.
final class IMAPConnectionLifetime {
    typealias Action = IMAPLifetimeGate.Action
    enum ReservationPhase { case created, queued, granted, started, retired }

    private struct RegisteredOperation {
        let isPendingLocked: () -> Bool
        let invalidateLocked: (IMAPAbortReason) -> [Action]
    }

    final class Reservation {
        let lease: QueueLease
        let admission: IMAPTerminal<QueueLease>
        let token: OperationToken?
        var task: UnsafeCurrentTask?
        var phase = ReservationPhase.created
        var failure: Error?

        init(
            generation: ConnectionGeneration,
            token: OperationToken?,
            task: UnsafeCurrentTask?,
            gate: IMAPLifetimeGate
        ) {
            lease = QueueLease(generation: generation)
            admission = IMAPTerminal(gate: gate)
            self.token = token
            self.task = task
        }
    }

    private let gate = IMAPLifetimeGate()
    private var generation = ConnectionGeneration()
    private var abortReason: IMAPAbortReason?
    private var operations: [OperationToken: RegisteredOperation] = [:]
    private var reservations: [QueueLease: Reservation] = [:]
    private var waiters: [Reservation] = []
    private var owners: Set<QueueLease> = []
    private var ownerTask: UnsafeCurrentTask?

    var currentGeneration: ConnectionGeneration { gate.withLock { generation } }

    func registerOperation<Value>(of type: Value.Type = Value.self) -> (OperationToken, IMAPTerminal<Value>) {
        let terminal = IMAPTerminal<Value>(gate: gate)
        let (token, actions) = gate.withLock { () -> (OperationToken, [Action]) in
            let token = OperationToken(generation: generation)
            if let abortReason {
                return (token, terminal.settleLocked(.failure(abortReason)) ?? [])
            }
            operations[token] = RegisteredOperation(
                isPendingLocked: { terminal.isPendingLocked },
                invalidateLocked: { terminal.settleLocked(.failure($0)) ?? [] }
            )
            return (token, [])
        }
        terminal.addCleanup { [weak self] in self?.retireOperation(token) }
        actions.forEach { $0() }
        return (token, terminal)
    }

    private func retireOperation(_ token: OperationToken) {
        _ = gate.withLock { operations.removeValue(forKey: token) }
    }

    func validate(_ token: OperationToken) throws {
        try gate.withLock { try validateLocked(token) }
    }

    private func validateLocked(_ token: OperationToken) throws {
        guard token.generation == generation, abortReason == nil,
              operations[token]?.isPendingLocked() == true else {
            throw abortReason ?? IMAPAbortReason.connectionAborted
        }
    }

    /// Invalidation claims all results under the same gate as completion. Active
    /// closures are not cancelled here; their eventual lease releases are harmless.
    func invalidate(reason: IMAPAbortReason = .connectionAborted) {
        let actions = gate.withLock { () -> [Action] in
            guard abortReason == nil else { return [] }
            abortReason = reason
            var actions = operations.values.flatMap { $0.invalidateLocked(reason) }
            operations.removeAll()
            for reservation in reservations.values {
                reservation.phase = .retired
                reservation.task = nil
                reservation.failure = reason
                actions += reservation.admission.settleLocked(.failure(reason)) ?? []
            }
            reservations.removeAll()
            waiters.removeAll()
            owners.removeAll()
            ownerTask = nil
            return actions
        }
        actions.forEach { $0() }
    }

    @discardableResult
    func rearm() -> ConnectionGeneration {
        gate.withLock {
            if abortReason != nil {
                generation = ConnectionGeneration()
                abortReason = nil
            }
            return generation
        }
    }

    /// Created before installing the cancellation handler, so cancellation can
    /// retire the record before enqueue or continuation installation.
    func makeReservation(token: OperationToken?, task: UnsafeCurrentTask?) throws -> Reservation {
        try gate.withLock {
            if let token { try validateLocked(token) }
            if let abortReason { throw abortReason }
            let reservation = Reservation(generation: generation, token: token, task: task, gate: gate)
            reservations[reservation.lease] = reservation
            return reservation
        }
    }

    func enqueue(_ reservation: Reservation) {
        let actions = gate.withLock { () -> [Action] in
            guard reservation.phase == .created else { return [] }
            if owners.isEmpty || sameTask(reservation.task, ownerTask) {
                return grantLocked(reservation)
            }
            reservation.phase = .queued
            waiters.append(reservation)
            return []
        }
        actions.forEach { $0() }
    }

    func start(_ reservation: Reservation) throws {
        try gate.withLock {
            if let failure = reservation.failure { throw failure }
            if let token = reservation.token { try validateLocked(token) }
            guard reservation.lease.generation == generation, abortReason == nil,
                  reservation.phase == .granted else {
                throw abortReason ?? IMAPAbortReason.connectionAborted
            }
            reservation.phase = .started
        }
    }

    func cancel(_ reservation: Reservation) {
        let actions = gate.withLock { () -> [Action] in
            switch reservation.phase {
                case .started, .retired:
                    // Active task cancellation policy belongs to #293.
                    return []
                case .created, .queued, .granted:
                    reservation.failure = CancellationError()
                    let actions = retireLocked(reservation)
                    return (reservation.admission.settleLocked(.failure(CancellationError())) ?? []) + actions
            }
        }
        actions.forEach { $0() }
    }

    func release(_ reservation: Reservation) {
        let actions = gate.withLock { retireLocked(reservation) }
        actions.forEach { $0() }
    }

    private func retireLocked(_ reservation: Reservation) -> [Action] {
        guard reservation.phase != .retired else { return [] }
        reservation.phase = .retired
        reservation.task = nil
        reservations.removeValue(forKey: reservation.lease)
        waiters.removeAll { $0.lease == reservation.lease }
        owners.remove(reservation.lease)
        guard owners.isEmpty else { return [] }
        ownerTask = nil
        guard !waiters.isEmpty else { return [] }
        return grantLocked(waiters.removeFirst())
    }

    private func grantLocked(_ reservation: Reservation) -> [Action] {
        reservation.phase = .granted
        ownerTask = reservation.task
        owners.insert(reservation.lease)
        return reservation.admission.settleLocked(.success(reservation.lease)) ?? []
    }

    private func sameTask(_ lhs: UnsafeCurrentTask?, _ rhs: UnsafeCurrentTask?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs == rhs
    }

    /// Internal diagnostics for deterministic admission tests.
    var reservationCount: Int { gate.withLock { reservations.count } }
}
