import Foundation
import Logging
import NIO
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Resilient IDLE Recovery and Event Drain

extension IMAPResilientIdleRunner {
    /// Buffered events drained after a DONE/NOOP probe.
    struct PostIdleEvents {
        var noopEvents: [IMAPServerEvent] = []
        var bufferedEvents: [IMAPServerEvent] = []

        var allEvents: [IMAPServerEvent] {
            noopEvents + bufferedEvents
        }

        var sawBye: Bool {
            allEvents.contains { event in
                if case .bye = event { return true }
                return false
            }
        }

        var byeMessage: String? {
            allEvents.compactMap { event -> String? in
                guard case let .bye(message) = event else { return nil }
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
            try await context.connection.connect()
            try await context.authentication.authenticate(on: context.connection)
            let selectCommand = SelectMailboxCommand(mailboxName: context.resolvedMailbox)
            _ = try await context.connection.executeCommand(selectCommand)

            state.resetAfterReconnect(configuration: context.configuration)
            context.logger.info("Reconnected IDLE session for mailbox '\(context.mailbox)'")
        } catch {
            state.reconnectAttempt += 1
            let delay = reconnectDelay(
                attempt: state.reconnectAttempt,
                configuration: context.configuration
            )
            // swiftlint:disable:next line_length
            context.logger.info("Cycle \(state.cycleCount): routine reconnect failed after server close '\(String(describing: error))'; retry \(state.reconnectAttempt) in \(delay)s")
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Generic error recovery path: log, back off, reconnect best-effort.
    static func handleCycleError(
        _ error: Error,
        context: IdleCycleContext,
        state: inout IdleCycleState
    ) async {
        state.reconnectAttempt += 1
        let delay = reconnectDelay(attempt: state.reconnectAttempt, configuration: context.configuration)
        // swiftlint:disable:next line_length
        context.logger.warning("Cycle \(state.cycleCount): encountered error '\(String(describing: error))'; reconnect attempt \(state.reconnectAttempt) in \(delay)s")

        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        if Task.isCancelled { return }

        do {
            try? await context.connection.done(timeoutSeconds: context.configuration.doneTimeout)
            try? await context.connection.disconnect()

            try await context.connection.connect()
            try await context.authentication.authenticate(on: context.connection)
            let selectCommand = SelectMailboxCommand(mailboxName: context.resolvedMailbox)
            _ = try await context.connection.executeCommand(selectCommand)

            state.resetAfterReconnect(configuration: context.configuration)
            context.logger.info("Reconnected IDLE session for mailbox '\(context.mailbox)'")
        } catch {
            // swiftlint:disable:next line_length
            context.logger.error("Reconnect attempt \(state.reconnectAttempt) failed for mailbox '\(context.mailbox)': \(String(describing: error))")
        }
    }
}
