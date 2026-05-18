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

            var continuationRef: AsyncStream<IMAPServerEvent>.Continuation!
            let wrappedEvents = AsyncStream<IMAPServerEvent> { continuation in
                continuationRef = continuation
            }

            let continuation = continuationRef!
            let serverHost = self.host
            let serverPort = self.port

            let cycleTask = Task.detached { [idleGroup] in
                enum CycleTrigger: String {
                    case noop
                    case renewal
                }

                enum CycleResult {
                    case timer(CycleTrigger)
                    case streamEnded(sawBye: Bool, byeMessage: String?)
                }

                let cycleLoggerLabel = "com.cocoanetics.SwiftMail.IdleCycle.\(connection.identifier)"
                var cycleLogger = Logger(label: cycleLoggerLabel)
                cycleLogger[metadataKey: "imap.host"] = .string(serverHost)
                cycleLogger[metadataKey: "imap.port"] = .stringConvertible(serverPort)
                cycleLogger[metadataKey: "imap.mailbox"] = .string(resolvedMailbox)
                cycleLogger[metadataKey: "imap.connection_id"] = .string(connection.identifier)
                cycleLogger[metadataKey: "imap.connection_role"] = .string(connection.role)

                let reconnectDelay: (Int) -> TimeInterval = { attempt in
                    let exponent = min(max(attempt - 1, 0), 10)
                    let multiplier = Double(1 << exponent)
                    let baseDelay = min(
                        idleConfiguration.reconnectBaseDelay * multiplier,
                        idleConfiguration.reconnectMaxDelay
                    )
                    let jitterFactor = idleConfiguration.reconnectJitterFactor
                    guard jitterFactor > 0 else { return baseDelay }
                    let jittered = baseDelay * (1 + Double.random(in: -jitterFactor...jitterFactor))
                    return max(0, jittered)
                }

                var cycleCount = 0
                var reconnectAttempt = 0
                var nextNoopAt: Date? = idleConfiguration.postIdleNoopEnabled
                    ? Date().addingTimeInterval(idleConfiguration.noopInterval)
                    : nil
                var nextRenewalAt = Date().addingTimeInterval(idleConfiguration.renewalInterval)

                let startInfo = "Idle reliability task started for mailbox '\(mailbox)'"
                    + " (postIdleNoop=\(idleConfiguration.postIdleNoopEnabled)"
                    + " noopInterval=\(idleConfiguration.noopInterval)s"
                    + " renewal=\(idleConfiguration.renewalInterval)s)"
                cycleLogger.info("\(startInfo)")

                while !Task.isCancelled {
                    do {
                        cycleCount += 1
                        cycleLogger.debug("Cycle \(cycleCount): starting IDLE")

                        let idleStream = try await connection.idle()

                        let now = Date()
                        let secondsToNoop = nextNoopAt.map { max($0.timeIntervalSince(now), 0) } ?? .infinity
                        let secondsToRenewal = max(nextRenewalAt.timeIntervalSince(now), 0)
                        let trigger: CycleTrigger = secondsToRenewal <= secondsToNoop ? .renewal : .noop
                        let waitSeconds = trigger == .renewal ? secondsToRenewal : secondsToNoop

                        let cycleResult = await withTaskGroup(of: CycleResult.self) { group -> CycleResult in
                            group.addTask {
                                var sawBye = false
                                var byeMessage: String?
                                for await event in idleStream {
                                    continuation.yield(event)
                                    if case .bye(let message) = event {
                                        sawBye = true
                                        byeMessage = message
                                        break
                                    }
                                }
                                return .streamEnded(sawBye: sawBye, byeMessage: byeMessage)
                            }

                            group.addTask {
                                if waitSeconds > 0 {
                                    try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                                }
                                return .timer(trigger)
                            }

                            let first = await group.next() ?? .streamEnded(sawBye: false, byeMessage: nil)
                            group.cancelAll()
                            return first
                        }

                        if Task.isCancelled { break }

                        switch cycleResult {
                            case .streamEnded(let sawBye, let byeMessage):
                                if sawBye {
                                    let message = byeMessage ?? "<no message>"
                                    cycleLogger.info("Cycle \(cycleCount): Server closed connection: \(message)")

                                    do {
                                        try? await connection.disconnect()

                                        try await connection.connect()
                                        try await authentication.authenticate(on: connection)
                                        _ = try await connection.executeCommand(
                                            SelectMailboxCommand(mailboxName: resolvedMailbox)
                                        )

                                        let reconnectedAt = Date()
                                        nextNoopAt = idleConfiguration.postIdleNoopEnabled
                                            ? reconnectedAt.addingTimeInterval(idleConfiguration.noopInterval)
                                            : nil
                                        nextRenewalAt = reconnectedAt.addingTimeInterval(
                                            idleConfiguration.renewalInterval
                                        )
                                        reconnectAttempt = 0

                                        cycleLogger.info("Reconnected IDLE session for mailbox '\(mailbox)'")
                                        continue
                                    } catch {
                                        reconnectAttempt += 1
                                        let delay = reconnectDelay(reconnectAttempt)
                                        let errorDescription = String(describing: error)
                                        let info = "Cycle \(cycleCount): routine reconnect failed"
                                            + " after server close '\(errorDescription)';"
                                            + " retry \(reconnectAttempt) in \(delay)s"
                                        cycleLogger.info("\(info)")

                                        if delay > 0 {
                                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                                        }
                                        continue
                                    }
                                } else {
                                    cycleLogger.warning(
                                        "Cycle \(cycleCount): IDLE stream ended unexpectedly; reconnecting"
                                    )
                                }
                                throw IMAPConnectionError.disconnected

                            case .timer(let checkpoint):
                                let debugMessage = "Cycle \(cycleCount):"
                                    + " checkpoint=\(checkpoint.rawValue), sending DONE"
                                cycleLogger.debug("\(debugMessage)")
                                try await connection.done(timeoutSeconds: idleConfiguration.doneTimeout)

                                var noopEvents: [IMAPServerEvent] = []
                                if idleConfiguration.postIdleNoopEnabled {
                                    if idleConfiguration.postIdleNoopDelay > 0 {
                                        try? await Task.sleep(
                                            nanoseconds: UInt64(idleConfiguration.postIdleNoopDelay * 1_000_000_000)
                                        )
                                    }
                                    cycleLogger.debug("Cycle \(cycleCount): sending NOOP")
                                    noopEvents = try await connection.noop()
                                    if !noopEvents.isEmpty {
                                        cycleLogger.debug(
                                            "Cycle \(cycleCount): NOOP returned \(noopEvents.count) event(s)"
                                        )
                                    }
                                } else {
                                    cycleLogger.debug("Cycle \(cycleCount): post-IDLE NOOP probe disabled")
                                }
                                for event in noopEvents {
                                    continuation.yield(event)
                                }

                                let bufferedEvents = connection.drainBufferedEvents()
                                if !bufferedEvents.isEmpty {
                                    cycleLogger.debug(
                                        "Cycle \(cycleCount): drained \(bufferedEvents.count) buffered event(s)"
                                    )
                                }
                                for event in bufferedEvents {
                                    continuation.yield(event)
                                }

                                let sawByeEvent = (noopEvents + bufferedEvents).contains { event in
                                    if case .bye = event { return true }
                                    return false
                                }
                                if sawByeEvent {
                                    let byeMessage = (noopEvents + bufferedEvents).compactMap { event -> String? in
                                        guard case .bye(let message) = event else { return nil }
                                        return message ?? "<no message>"
                                    }.first ?? "<no message>"
                                    cycleLogger.info("Cycle \(cycleCount): Server closed connection: \(byeMessage)")

                                    do {
                                        try? await connection.disconnect()

                                        try await connection.connect()
                                        try await authentication.authenticate(on: connection)
                                        _ = try await connection.executeCommand(
                                            SelectMailboxCommand(mailboxName: resolvedMailbox)
                                        )

                                        let reconnectedAt = Date()
                                        nextNoopAt = idleConfiguration.postIdleNoopEnabled
                                            ? reconnectedAt.addingTimeInterval(idleConfiguration.noopInterval)
                                            : nil
                                        nextRenewalAt = reconnectedAt.addingTimeInterval(
                                            idleConfiguration.renewalInterval
                                        )
                                        reconnectAttempt = 0

                                        cycleLogger.info("Reconnected IDLE session for mailbox '\(mailbox)'")
                                        continue
                                    } catch {
                                        reconnectAttempt += 1
                                        let delay = reconnectDelay(reconnectAttempt)
                                        let errorDescription = String(describing: error)
                                        let info = "Cycle \(cycleCount): routine reconnect failed"
                                            + " after server close '\(errorDescription)';"
                                            + " retry \(reconnectAttempt) in \(delay)s"
                                        cycleLogger.info("\(info)")

                                        if delay > 0 {
                                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                                        }
                                        continue
                                    }
                                }

                                let resumedAt = Date()
                                nextNoopAt = idleConfiguration.postIdleNoopEnabled
                                    ? resumedAt.addingTimeInterval(idleConfiguration.noopInterval)
                                    : nil
                                if checkpoint == .renewal || resumedAt >= nextRenewalAt {
                                    nextRenewalAt = resumedAt.addingTimeInterval(idleConfiguration.renewalInterval)
                                    cycleLogger.debug("Cycle \(cycleCount): renewed IDLE window")
                                }

                                reconnectAttempt = 0
                        }
                    } catch {
                        if Task.isCancelled { break }

                        reconnectAttempt += 1
                        let delay = reconnectDelay(reconnectAttempt)
                        let errorDescription = String(describing: error)
                        let warning = "Cycle \(cycleCount): encountered error '\(errorDescription)';"
                            + " reconnect attempt \(reconnectAttempt) in \(delay)s"
                        cycleLogger.warning("\(warning)")

                        if delay > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        }

                        if Task.isCancelled { break }

                        do {
                            try? await connection.done(timeoutSeconds: idleConfiguration.doneTimeout)
                            try? await connection.disconnect()

                            try await connection.connect()
                            try await authentication.authenticate(on: connection)
                            _ = try await connection.executeCommand(SelectMailboxCommand(mailboxName: resolvedMailbox))

                            let reconnectedAt = Date()
                            nextNoopAt = idleConfiguration.postIdleNoopEnabled
                                ? reconnectedAt.addingTimeInterval(idleConfiguration.noopInterval)
                                : nil
                            nextRenewalAt = reconnectedAt.addingTimeInterval(idleConfiguration.renewalInterval)

                            cycleLogger.info("Reconnected IDLE session for mailbox '\(mailbox)'")
                        } catch {
                            let errorDescription = String(describing: error)
                            let errorMessage = "Reconnect attempt \(reconnectAttempt)"
                                + " failed for mailbox '\(mailbox)': \(errorDescription)"
                            cycleLogger.error("\(errorMessage)")
                        }
                    }
                }

                continuation.finish()
                try? await idleGroup.shutdownGracefully()
            }

            let session = IMAPIdleSession(events: wrappedEvents) { [weak self] in
                cycleTask.cancel()
                guard let self else { return }
                try await self.endIdleSession(id: sessionID)
            }

            return session
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
}
