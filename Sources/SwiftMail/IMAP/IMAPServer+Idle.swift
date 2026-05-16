import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

// MARK: - Idle

extension IMAPServer {
    /// Begin an IDLE session and receive server events
    ///
    /// **Manual Cleanup**: When cancelling IDLE tasks, call `done()` in your cancellation
    ///   handlers to properly terminate the IDLE session. The actor ensures all calls
    ///   are serialized, preventing race conditions.
    ///
    /// - Important: If you receive a `.bye` event, the server is terminating the entire
    ///   connection, not just the IDLE session. You should stop processing the stream
    ///   immediately, as the connection will be closed by the server.
    ///
    /// - Important: If you have multiple connections looking at the same mailbox, refresh
    ///   their state (for example by issuing `noop()`) when an IDLE event indicates changes
    ///   like new messages or expunges. This keeps counts and sequence numbers in sync.
    ///
    /// - Returns: An AsyncStream of server events during the IDLE session
    /// - Throws: IMAPError if IDLE is not supported or already active
    public func idle() async throws -> AsyncStream<IMAPServerEvent> {
        try await primaryConnection.idle()
    }

    /// Begin a resilient IDLE session for a specific mailbox on a dedicated connection.
    /// The returned session must be ended by calling `done()` on the session,
    /// or by calling `disconnect()` on the server.
    ///
    /// This stream is self-healing:
    /// - IDLE is renewed every `configuration.renewalInterval` (default 285 seconds)
    /// - optional DONE → NOOP → re-IDLE probes run every `configuration.noopInterval`
    ///   when `configuration.postIdleNoopEnabled` is true
    /// - dropped connections are automatically reconnected and re-selected
    ///
    /// - Important: If other connections have the same mailbox selected, refresh them
    ///   (for example by issuing `noop()`) when this session reports changes, to keep
    ///   counts and sequence numbers accurate across connections.
    /// - Parameter mailbox: The mailbox to watch for changes.
    /// - Parameter configuration: Reliability tuning for IDLE renewal/heartbeat/reconnect.
    public func idle(
        on mailbox: String,
        configuration: IMAPIdleConfiguration = .default
    ) async throws -> IMAPIdleSession {
        let idleConfiguration = try configuration.validated()

        guard let authentication = authentication else {
            throw IMAPError.commandFailed("Authentication required before starting IDLE on a mailbox")
        }

        let sessionID = UUID()
        let resolvedMailbox = resolveMailboxPath(mailbox)
        // Each IDLE connection gets its own EventLoopGroup so that IMAPServer.deinit
        // shutting down the primary group cannot pull the rug from under a long-lived
        // IDLE cycle task (which is Task.detached and can outlive the server).
        let idleGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connection = makeIdleConnection(sessionID: sessionID, mailbox: resolvedMailbox, group: idleGroup)
        idleConnections[sessionID] = IdleConnection(mailbox: resolvedMailbox, connection: connection)

        do {
            try await connection.connect()
            try await authentication.authenticate(on: connection)
            _ = try await connection.executeCommand(SelectMailboxCommand(mailboxName: resolvedMailbox))

            let request = IdleSessionRequest(
                sessionID: sessionID,
                mailbox: mailbox,
                resolvedMailbox: resolvedMailbox,
                connection: connection,
                idleGroup: idleGroup,
                configuration: idleConfiguration,
                authentication: authentication
            )
            return startResilientIdleSession(request: request)
        } catch {
            idleConnections[sessionID] = nil
            try? await connection.disconnect()
            try? await idleGroup.shutdownGracefully()
            throw error
        }
    }

    /// Compatibility wrapper for the previous IDLE API.
    ///
    /// The provided interval maps to heartbeat NOOP checkpoints.
    /// Renewal remains at the default strategy interval unless overridden via
    /// `idle(on:configuration:)`.
    @available(*, deprecated, message: "Use idle(on:configuration:) for full reliability configuration.")
    public func idle(on mailbox: String, cycleInterval: TimeInterval) async throws -> IMAPIdleSession {
        var configuration = IMAPIdleConfiguration.default
        configuration.noopInterval = cycleInterval
        configuration.postIdleNoopEnabled = true
        return try await idle(on: mailbox, configuration: configuration)
    }

    /// Terminate the current IDLE session
    ///
    /// **Note**: Call this method in cancellation handlers to properly clean up IDLE sessions.
    ///   The actor ensures this is safe to call even during rapid cancellation/restart cycles.
    ///
    /// This method is safe to call even if the server has already terminated the IDLE session
    /// (e.g., by sending a BYE response) or if automatic cleanup has already occurred.
    public func done() async throws {
        try await primaryConnection.done()
    }

    /// Send a NOOP command and collect unsolicited responses.
    public func noop() async throws -> [IMAPServerEvent] {
        try await primaryConnection.noop()
    }

    /// Wire up the AsyncStream + detached cycle task for a resilient IDLE session.
    func startResilientIdleSession(request: IdleSessionRequest) -> IMAPIdleSession {
        var continuationRef: AsyncStream<IMAPServerEvent>.Continuation!
        let wrappedEvents = AsyncStream<IMAPServerEvent> { continuation in
            continuationRef = continuation
        }

        let continuation = continuationRef!

        let cycleLogger = IMAPResilientIdleRunner.makeCycleLogger(
            connection: request.connection,
            host: self.host,
            port: self.port,
            mailbox: request.resolvedMailbox
        )

        let context = IdleCycleContext(
            connection: request.connection,
            mailbox: request.mailbox,
            resolvedMailbox: request.resolvedMailbox,
            configuration: request.configuration,
            authentication: request.authentication,
            continuation: continuation,
            logger: cycleLogger
        )

        let idleGroup = request.idleGroup
        let sessionID = request.sessionID
        let cycleTask = Task.detached { [idleGroup] in
            await IMAPResilientIdleRunner.run(context: context)
            continuation.finish()
            try? await idleGroup.shutdownGracefully()
        }

        return IMAPIdleSession(events: wrappedEvents) { [weak self] in
            cycleTask.cancel()
            guard let self else { return }
            try await self.endIdleSession(id: sessionID)
        }
    }
}

/// Bundled parameters for starting a resilient IDLE session.
struct IdleSessionRequest {
    let sessionID: UUID
    let mailbox: String
    let resolvedMailbox: String
    let connection: IMAPConnection
    let idleGroup: EventLoopGroup
    let configuration: IMAPIdleConfiguration
    let authentication: IMAPServer.Authentication
}
