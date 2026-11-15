import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

// MARK: - Resilient IDLE Recovery and Event Drain

extension IMAPResilientIdleRunner {
    /// Buffered events drained after a DONE/NOOP probe.
    struct PostIdleEvents {
        var noopEvents: [IMAPServerEvent] = []
        var bufferedEvents: [IMAPServerEvent] = []

        var allEvents: [IMAPServerEvent] { noopEvents + bufferedEvents }

        var sawBye: Bool {
            allEvents.contains { event in
                if case .bye = event { return true }
                return false
            }
        }

        var byeMessage: String? {
            allEvents.compactMap { event -> String? in
                guard case .bye(let message) = event else { return nil }
                return message ?? "<no message>"
            }.first
        }
    }

    /// Run optional NOOP probe and drain any buffered events.
    static func collectPostIdleEvents(
        context: IdleCycleContext,
        state: IdleCycleState
    ) async throws -> PostIdleEvents {
        var result = PostIdleEvents()

        if context.configuration.postIdleNoopEnabled {
            if context.configuration.postIdleNoopDelay > 0 {
                let delayNanos = UInt64(context.configuration.postIdleNoopDelay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delayNanos)
            }
            context.logger.debug("Cycle \(state.cycleCount): sending NOOP")
            result.noopEvents = try await context.connection.noop()
            if !result.noopEvents.isEmpty {
                context.logger.debug("Cycle \(state.cycleCount): NOOP returned \(result.noopEvents.count) event(s)")
            }
        } else {
            context.logger.debug("Cycle \(state.cycleCount): post-IDLE NOOP probe disabled")
        }

        result.bufferedEvents = context.connection.drainBufferedEvents()
        if !result.bufferedEvents.isEmpty {
            context.logger.debug("Cycle \(state.cycleCount): drained \(result.bufferedEvents.count) buffered event(s)")
        }

        return result
    }

    /// Update the IDLE/NOOP timers after a successful checkpoint.
    static func advanceTimersAfterCheckpoint(
        checkpoint: IdleCycleTrigger,
        context: IdleCycleContext,
        state: inout IdleCycleState
    ) {
        let resumedAt = Date()
        state.nextNoopAt = context.configuration.postIdleNoopEnabled
            ? resumedAt.addingTimeInterval(context.configuration.noopInterval)
            : nil
        if checkpoint == .renewal || resumedAt >= state.nextRenewalAt {
            state.nextRenewalAt = resumedAt.addingTimeInterval(context.configuration.renewalInterval)
            context.logger.debug("Cycle \(state.cycleCount): renewed IDLE window")
        }

        state.reconnectAttempt = 0
    }

    /// Disconnect, reconnect, re-authenticate, and re-select the mailbox after a BYE.
    /// Logs and applies backoff on failure.
    static func attemptRoutineReconnect(
        context: IdleCycleContext,
        state: inout IdleCycleState
    ) async throws {
        do {
            try? await context.connection.disconnect()
            // Teardown may have stopped the session while the disconnect above was
            // in flight. The retained session token fences each step below as well.
            guard context.session.isActive, !Task.isCancelled else { return }
            try await reestablishSession(context: context)

            state.resetAfterReconnect(configuration: context.configuration)
            context.logger.info("Reconnected IDLE session for mailbox '\(context.mailbox)'")
        } catch {
            state.reconnectAttempt += 1
            let delay = reconnectDelay(
                attempt: state.reconnectAttempt,
                configuration: context.configuration
            )
            let errorDescription = String(describing: error)
            let info = "Cycle \(state.cycleCount): routine reconnect failed after server close"
                + " '\(errorDescription)'; retry \(state.reconnectAttempt) in \(delay)s"
            context.logger.info("\(info)")
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Dial, authenticate and SELECT on the non-rearming path. Each step runs under
    /// the retained session token and is checked again once it returns.
    static func reestablishSession(context: IdleCycleContext) async throws {
        try context.session.validate()
        try await context.connection.connect()
        try context.session.validate()
        try await context.authentication.authenticate(on: context.connection)
        try context.session.validate()
        let selectCommand = SelectMailboxCommand(mailboxName: context.resolvedMailbox)
        _ = try await context.connection.executeCommand(selectCommand)
        try context.session.validate()
    }

    /// Generic error recovery path: log, back off, reconnect best-effort.
    static func handleCycleError(
        _ error: Error,
        context: IdleCycleContext,
        state: inout IdleCycleState
    ) async {
        state.reconnectAttempt += 1
        let delay = reconnectDelay(attempt: state.reconnectAttempt, configuration: context.configuration)
        let errorDescription = String(describing: error)
        let warning = "Cycle \(state.cycleCount): encountered error '\(errorDescription)';"
            + " reconnect attempt \(state.reconnectAttempt) in \(delay)s"
        context.logger.warning("\(warning)")

        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        guard context.session.isActive, !Task.isCancelled else { return }

        do {
            try? await context.connection.done(timeoutSeconds: context.configuration.doneTimeout)
            try? await context.connection.disconnect()

            // Same window as attemptRoutineReconnect: the check above ran before
            // done/disconnect, and the session may have been stopped since.
            guard context.session.isActive, !Task.isCancelled else { return }
            try await reestablishSession(context: context)

            state.resetAfterReconnect(configuration: context.configuration)
            context.logger.info("Reconnected IDLE session for mailbox '\(context.mailbox)'")
        } catch {
            let errorDescription = String(describing: error)
            let errorMessage = "Reconnect attempt \(state.reconnectAttempt) failed for mailbox"
                + " '\(context.mailbox)': \(errorDescription)"
            context.logger.error("\(errorMessage)")
        }
    }
}
