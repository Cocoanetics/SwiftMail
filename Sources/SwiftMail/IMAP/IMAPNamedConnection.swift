import Foundation
@preconcurrency import NIOIMAPCore

/// A user-controlled, reusable IMAP connection managed by ``IMAPServer``.
///
/// Instances are obtained via ``IMAPServer/connection(named:)``.
/// The server handles lifecycle bootstrap/authentication and teardown; callers decide
/// which mailbox and commands run on each named connection.
public actor IMAPNamedConnection {
    public let name: String

    // Widened from `private` to internal so the extensions split across files
    // (Mailbox/Idle/Fetch/Search/Manipulation) can reach them; not part of the
    // public API.
    let connection: IMAPConnection
    let authenticateOnConnection: @Sendable (IMAPConnection) async throws -> Void

    /// The timestamp of the last successfully completed command on this connection.
    /// Useful for implementing staleness checks in ephemeral connection patterns.
    public private(set) var lastActivity: Date?
    private var authenticationAttempt: SharedAttempt<Void>?

    var authenticationWaiterCountForTesting: Int {
        // Preserve the old diagnostic's follower-only count.
        max(0, (authenticationAttempt?.waiterCount ?? 0) - 1)
    }

    var authenticationAttemptForTesting: SharedAttempt<Void>? { authenticationAttempt }

    init(
        name: String,
        connection: IMAPConnection,
        authenticateOnConnection: @escaping @Sendable (IMAPConnection) async throws -> Void
    ) {
        self.name = name
        self.connection = connection
        self.authenticateOnConnection = authenticateOnConnection
    }

    /// Whether the underlying transport channel is currently active.
    public var isConnected: Bool {
        connection.isConnected
    }

    /// Whether this connection currently has an authenticated IMAP session.
    public var isAuthenticated: Bool {
        connection.isAuthenticated
    }

    /// Connect (or reconnect) the underlying transport and ensure authentication.
    public func connect() async throws {
        if connection.operationToken == nil { connection.lifetime.rearm() }
        try await connection.withOperationScope { [self] in
            try await connection.connect()
            try await ensureAuthenticated()
        }
    }

    /// Disconnect this named connection.
    public func disconnect() async throws {
        try await connection.disconnect()
    }

    /// Whether the server advertised UIDPLUS for this connection.
    public var supportsUIDPlus: Bool {
        capabilities.containsUIDPlusCapability
    }

    /// Whether the server advertised MOVE (RFC 6851) for this connection.
    ///
    /// This reports the latest advertised capability snapshot. Callers with a no-delete policy
    /// should pass ``MoveFallbackPolicy/disabled`` to ``move(messages:to:fallback:)`` instead of
    /// relying on this value as a separate guard; the operation refreshes authentication state,
    /// requires MOVE directly (without requiring UIDPLUS), and refuses before any fallback command.
    public var supportsMove: Bool {
        capabilities.containsMoveCapability
    }

    // MARK: - Internal Helpers

    /// Capabilities snapshot reused by the split extensions when deciding
    /// whether optional commands are supported.
    var capabilities: Set<NIOIMAPCore.Capability> {
        connection.capabilitiesSnapshot
    }

    /// Mark a successful command — invoked by helpers that talk directly to
    /// `connection` (idle, noop, fetchCapabilities, …).
    func recordActivity() throws {
        guard let token = connection.operationToken else { throw IMAPConnectionAbortedError() }
        try connection.lifetime.gate.withLock {
            try connection.lifetime.validateLocked(token)
            lastActivity = Date()
        }
    }

    func ensureAuthenticated() async throws {
        if connection.operationToken == nil {
            return try await connection.withOperationScope { [self] in
                try await ensureAuthenticated()
            }
        }
        try connection.validateOperation()
        let token = connection.operationToken
        if let attempt = authenticationAttempt,
           attempt.generation == token?.generation, !attempt.terminal.isSettled {
            try await attempt.value(parent: token)
            try connection.validateOperation()
            return
        }
        guard !connection.isAuthenticated else { return }
        let attempt = SharedAttempt<Void>(lifetime: connection.lifetime, parent: token)
        authenticationAttempt = attempt
        attempt.start(on: connection, operation: { [connection, authenticateOnConnection] in
            try await authenticateOnConnection(connection)
        }, completion: { [self] result in
            completeAuthentication(attempt, with: result)
        })
        try await attempt.value(parent: token)
        try connection.validateOperation()
    }

    private func completeAuthentication(_ attempt: SharedAttempt<Void>, with result: Result<Void, Error>) {
        guard authenticationAttempt?.id == attempt.id else { return }
        attempt.complete(result)
        if authenticationAttempt?.id == attempt.id { authenticationAttempt = nil }
    }

    func withAuthenticatedOperation<Value>(_ body: @escaping () async throws -> Value) async throws -> Value {
        try await connection.withOperationScope { [self] in
            try await ensureAuthenticated()
            return try await body()
        }
    }

    @discardableResult
    func executeCommand<CommandType: IMAPCommand>(
        _ command: CommandType
    ) async throws -> CommandType.ResultType {
        try await withAuthenticatedOperation { [self] in
            let result = try await connection.executeCommand(command)
            try recordActivity()
            return result
        }
    }

    func resolveMailboxPath(_ mailboxName: String) -> String {
        guard let namespaces = connection.namespacesSnapshot else {
            return mailboxName
        }
        return namespaces.resolveMailboxPath(mailboxName)
    }
}
