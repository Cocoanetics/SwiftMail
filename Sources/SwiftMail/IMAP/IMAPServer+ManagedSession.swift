import Foundation
import NIO

// MARK: - Managed Session Gate

/// Actor-owned admission state for the connections `IMAPServer` creates on the
/// caller's behalf: named connections (pending and published) and dedicated IDLE
/// sessions. The primary connection has its own lifetime and is only rearmed here.
struct IMAPManagedSessionGate {
    private(set) var generation = ConnectionGeneration()
    private(set) var abortReason: IMAPAbortReason?
    /// `disconnect()` calls still tearing down. They suspend while closing, so new
    /// creation is refused until they finish rather than escaping their snapshot.
    private var disconnectsInFlight = 0

    func validateAdmission() throws {
        if let abortReason { throw abortReason }
        if disconnectsInFlight > 0 { throw IMAPAbortReason.connectionAborted }
    }

    mutating func beginDisconnect() {
        disconnectsInFlight += 1
    }

    mutating func endDisconnect() {
        disconnectsInFlight -= 1
    }

    func isCurrent(_ expected: ConnectionGeneration) -> Bool {
        generation == expected && abortReason == nil
    }

    mutating func close(reason: IMAPAbortReason) {
        guard abortReason == nil else { return }
        abortReason = reason
    }

    /// A new generation, so completions captured before the rearm stay stale.
    mutating func rearm() {
        guard abortReason != nil else { return }
        abortReason = nil
        generation = ConnectionGeneration()
    }
}

extension IMAPServer {
    /// A named connection being created. The connection and attempt are registered
    /// before the first connect or authentication await.
    struct PendingNamedConnection {
        let attempt: SharedAttempt<IMAPNamedConnection>
        let connection: IMAPConnection
        let generation: ConnectionGeneration
    }

    /// Resources claimed by an invalidation. Transports are already closing; this
    /// only waits for runners and releases their event loop groups.
    struct ManagedSessionCleanup {
        let idleSessions: [IMAPDedicatedIdleSession]

        func run() async {
            for session in idleSessions { await session.finishTeardown() }
        }
    }

    /// Terminal, session-wide invalidation. Closes new-creation admission and
    /// invalidates every captured connection before any suspension; old named
    /// handles need their own explicit `connect()`. Public abort APIs build on this.
    func invalidateManagedSession(reason: IMAPAbortReason = .connectionAborted) async {
        let cleanup = invalidateManagedSessionNow(reason: reason)
        await cleanup.run()
    }

    func invalidateManagedSessionNow(reason: IMAPAbortReason = .connectionAborted) -> ManagedSessionCleanup {
        managedSession.close(reason: reason)
        let cleanup = detachManagedConnections(abortingNamed: true)
        primaryConnection.abortNow()
        return cleanup
    }

    /// Invalidates the primary connection only; named and dedicated work continues.
    func invalidatePrimaryConnection() {
        primaryConnection.abortNow()
    }

    /// Removes every managed record synchronously. Pending creations and dedicated
    /// sessions are aborted (their callers are settled at once); published named
    /// connections are aborted only for terminal invalidation.
    func detachManagedConnections(abortingNamed: Bool) -> ManagedSessionCleanup {
        let pending = pendingNamedConnections.values
        pendingNamedConnections.removeAll()
        let idle = idleConnections.values
        idleConnections.removeAll()
        for entry in pending { entry.connection.abortNow() }
        let sessions = idle.compactMap { entry in entry.session.beginTeardown() ? entry.session : nil }
        if abortingNamed {
            let named = namedConnections.values
            namedConnections.removeAll()
            for entry in named { entry.connection.abortNow() }
        }
        return ManagedSessionCleanup(idleSessions: sessions)
    }

    var pendingNamedConnectionForTesting: [String: PendingNamedConnection] { pendingNamedConnections }

    func setManagedConnectionCreatedForTesting(_ hook: ((IMAPConnection) -> Void)?) {
        managedConnectionCreatedForTesting = hook
    }

    func setNamedAttemptCompletedForTesting(_ hook: ((UUID) -> Void)?) {
        namedAttemptCompletedForTesting = hook
    }
}

/// A dedicated IDLE session's operation authority and its single teardown.
///
/// Every bootstrap and recovery step runs under `token`, so the connection's
/// `connect()` never rearms it and a stopped session cannot dial, authenticate,
/// SELECT or IDLE again. Stopping invalidates the token before the transport is
/// closed, and closing begins before the runner or the group is awaited.
final class IMAPDedicatedIdleSession: @unchecked Sendable {
    let id = UUID()
    let connection: IMAPConnection
    let idleGroup: EventLoopGroup
    /// The managed-session generation this session was admitted in.
    let generation: ConnectionGeneration
    private let token: OperationToken
    private let authority: IMAPTerminal<Void>
    // Access only under the connection lifetime gate.
    private var stopped = false
    private var cycleTask: Task<Void, Never>?

    init(connection: IMAPConnection, idleGroup: EventLoopGroup, generation: ConnectionGeneration) {
        self.connection = connection
        self.idleGroup = idleGroup
        self.generation = generation
        (token, authority) = connection.lifetime.registerOperation(of: Void.self)
    }

    var isActive: Bool {
        connection.lifetime.gate.withLock { !stopped }
    }

    func validate() throws {
        try connection.lifetime.gate.withLock {
            guard !stopped else { throw IMAPAbortReason.connectionAborted }
            try connection.lifetime.validateLocked(token)
        }
    }

    /// Runs `body` with the session's retained token as the connection's authority.
    func withAuthority<T>(_ body: () async throws -> T) async rethrows -> T {
        var tokens = IMAPOperationScope.tokens
        tokens[ObjectIdentifier(connection.lifetime)] = token
        return try await IMAPOperationScope.$tokens.withValue(tokens) { try await body() }
    }

    /// Runs bootstrap in a worker under the session token. The caller waits on a
    /// registered cell, so invalidation settles it even while a provider or a held
    /// transport step never returns.
    func bootstrap(_ body: @escaping @Sendable () async throws -> Void) async throws {
        let (_, result) = connection.lifetime.registerOperation(of: Void.self, parent: token)
        let worker = Task.detached { [self] in
            do {
                try await withAuthority { try await body() }
                result.complete(.success(()))
            } catch {
                result.complete(.failure(error))
            }
        }
        result.addCleanup { worker.cancel() }
        try await withTaskCancellationHandler {
            try await result.value()
        } onCancel: {
            result.complete(.failure(CancellationError()))
        }
        try validate()
    }

    /// Installs the cycle task unless the session was stopped first.
    func install(cycleTask: Task<Void, Never>) -> Bool {
        let installed = connection.lifetime.gate.withLock { () -> Bool in
            guard !stopped else { return false }
            self.cycleTask = cycleTask
            return true
        }
        if !installed { cycleTask.cancel() }
        return installed
    }

    /// Synchronous claim: stops recovery, then begins closing the transport. Only
    /// the first caller wins and owns `finishTeardown()`.
    func beginTeardown() -> Bool {
        let task = connection.lifetime.gate.withLock { () -> Task<Void, Never>?? in
            guard !stopped else { return nil }
            stopped = true
            return .some(cycleTask)
        }
        guard let task else { return false }
        authority.complete(.failure(IMAPAbortReason.connectionAborted))
        task?.cancel()
        connection.abortNow()
        return true
    }

    /// Waits for the runner, which can no longer act, then releases the group.
    func finishTeardown() async {
        let task = connection.lifetime.gate.withLock { cycleTask }
        await task?.value
        try? await idleGroup.shutdownGracefully()
    }

    func teardown() async {
        guard beginTeardown() else { return }
        await finishTeardown()
    }
}
