import Foundation
import Logging
import NIO
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Resilient IDLE Cycle Step Helpers

extension IMAPResilientIdleRunner {
    /// Start an IDLE and race the stream-end against the next checkpoint timer.
    static func runOneCycle(
        context: IdleCycleContext,
        state: IdleCycleState
    ) async throws -> IdleCycleResult {
        let idleStream = try await context.connection.idle()

        let now = Date()
        let secondsToNoop = state.nextNoopAt.map { max($0.timeIntervalSince(now), 0) } ?? .infinity
        let secondsToRenewal = max(state.nextRenewalAt.timeIntervalSince(now), 0)
        let trigger: IdleCycleTrigger = secondsToRenewal <= secondsToNoop ? .renewal : .noop
        let waitSeconds = trigger == .renewal ? secondsToRenewal : secondsToNoop

        return await raceIdleStreamAgainstTimer(
            idleStream: idleStream,
            trigger: trigger,
            waitSeconds: waitSeconds,
            continuation: context.continuation
        )
    }

    /// Race the IDLE stream consumer against a checkpoint timer.
    private static func raceIdleStreamAgainstTimer(
        idleStream: AsyncStream<IMAPServerEvent>,
        trigger: IdleCycleTrigger,
        waitSeconds: TimeInterval,
        continuation: AsyncStream<IMAPServerEvent>.Continuation
    ) async -> IdleCycleResult {
        await withTaskGroup(of: IdleCycleResult.self) { group -> IdleCycleResult in
            group.addTask {
                var sawBye = false
                var byeMessage: String?
                for await event in idleStream {
                    continuation.yield(event)
                    if case let .bye(message) = event {
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
    }

    /// Dispatch the cycle outcome: stream ended (with/without BYE) or timer fired.
    static func applyCycleResult(
        _ cycleResult: IdleCycleResult,
        context: IdleCycleContext,
        state: inout IdleCycleState
    ) async throws {
        switch cycleResult {
            case let .streamEnded(sawBye, byeMessage):
                try await handleStreamEnded(
                    sawBye: sawBye,
                    byeMessage: byeMessage,
                    context: context,
                    state: &state
                )

            case let .timer(checkpoint):
                try await handleTimer(checkpoint: checkpoint, context: context, state: &state)
        }
    }

    /// Stream end branch: reconnect on BYE, otherwise throw to trigger generic recovery.
    static func handleStreamEnded(
        sawBye: Bool,
        byeMessage: String?,
        context: IdleCycleContext,
        state: inout IdleCycleState
    ) async throws {
        if sawBye {
            let message = byeMessage ?? "<no message>"
            context.logger.info("Cycle \(state.cycleCount): Server closed connection: \(message)")
            try await attemptRoutineReconnect(context: context, state: &state)
            return
        }

        context.logger.warning("Cycle \(state.cycleCount): IDLE stream ended unexpectedly; reconnecting")
        throw IMAPConnectionError.disconnected
    }

    /// Timer branch: send DONE, optionally NOOP, drain buffered events, and either reconnect on BYE
    /// or advance timers.
    static func handleTimer(
        checkpoint: IdleCycleTrigger,
        context: IdleCycleContext,
        state: inout IdleCycleState
    ) async throws {
        context.logger.debug("Cycle \(state.cycleCount): checkpoint=\(checkpoint.rawValue), sending DONE")
        try await context.connection.done(timeoutSeconds: context.configuration.doneTimeout)

        let probeEvents = try await collectPostIdleEvents(context: context, state: state)

        for event in probeEvents.allEvents {
            context.continuation.yield(event)
        }

        if probeEvents.sawBye {
            let byeText = probeEvents.byeMessage ?? "<no message>"
            context.logger.info("Cycle \(state.cycleCount): Server closed connection: \(byeText)")
            try await attemptRoutineReconnect(context: context, state: &state)
            return
        }

        advanceTimersAfterCheckpoint(checkpoint: checkpoint, context: context, state: &state)
    }
}
