import Foundation
import Logging
import NIO
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Resilient IDLE Cycle Runner

/// Holds the bookkeeping state for a single resilient IDLE session.
struct IdleCycleState {
    var cycleCount = 0
    var reconnectAttempt = 0
    var nextNoopAt: Date?
    var nextRenewalAt: Date

    init(configuration: IMAPIdleConfiguration) {
        let now = Date()
        nextNoopAt = configuration.postIdleNoopEnabled
            ? now.addingTimeInterval(configuration.noopInterval)
            : nil
        nextRenewalAt = now.addingTimeInterval(configuration.renewalInterval)
    }

    mutating func resetAfterReconnect(configuration: IMAPIdleConfiguration) {
        let reconnectedAt = Date()
        nextNoopAt = configuration.postIdleNoopEnabled
            ? reconnectedAt.addingTimeInterval(configuration.noopInterval)
            : nil
        nextRenewalAt = reconnectedAt.addingTimeInterval(configuration.renewalInterval)
        reconnectAttempt = 0
    }
}

/// Trigger that ended the current IDLE window.
enum IdleCycleTrigger: String {
    case noop
    case renewal
}

/// Outcome of waiting for either the stream to end or a checkpoint timer to fire.
enum IdleCycleResult {
    case timer(IdleCycleTrigger)
    case streamEnded(sawBye: Bool, byeMessage: String?)
}

/// Bundles the per-session configuration and references the resilient IDLE cycle
/// uses across helper functions. Reduces the parameter count of dispatch helpers.
struct IdleCycleContext {
    let connection: IMAPConnection
    let mailbox: String
    let resolvedMailbox: String
    let configuration: IMAPIdleConfiguration
    let authentication: IMAPServer.Authentication
    let continuation: AsyncStream<IMAPServerEvent>.Continuation
    let logger: Logger
}

/// Stateless helper that runs the resilient IDLE cycle.
///
/// This is intentionally not actor-isolated so it can run inside a `Task.detached`
/// without serializing on the owning ``IMAPServer``.
enum IMAPResilientIdleRunner {
    static func run(context: IdleCycleContext) async {
        var state = IdleCycleState(configuration: context.configuration)

        let configuration = context.configuration
        // swiftlint:disable:next line_length
        context.logger.info("Idle reliability task started for mailbox '\(context.mailbox)' (postIdleNoop=\(configuration.postIdleNoopEnabled) noopInterval=\(configuration.noopInterval)s renewal=\(configuration.renewalInterval)s)")

        while !Task.isCancelled {
            do {
                state.cycleCount += 1
                context.logger.debug("Cycle \(state.cycleCount): starting IDLE")

                let cycleResult = try await runOneCycle(context: context, state: state)
                if Task.isCancelled { break }

                try await applyCycleResult(cycleResult, context: context, state: &state)
            } catch {
                if Task.isCancelled { break }
                await handleCycleError(error, context: context, state: &state)
            }
        }
    }

    /// Build the logger used to annotate cycle events.
    static func makeCycleLogger(
        connection: IMAPConnection,
        host: String,
        port: Int,
        mailbox: String
    ) -> Logger {
        let cycleLoggerLabel = "com.cocoanetics.SwiftMail.IdleCycle.\(connection.identifier)"
        var cycleLogger = Logger(label: cycleLoggerLabel)
        cycleLogger[metadataKey: "imap.host"] = .string(host)
        cycleLogger[metadataKey: "imap.port"] = .stringConvertible(port)
        cycleLogger[metadataKey: "imap.mailbox"] = .string(mailbox)
        cycleLogger[metadataKey: "imap.connection_id"] = .string(connection.identifier)
        cycleLogger[metadataKey: "imap.connection_role"] = .string(connection.role)
        return cycleLogger
    }

    /// Compute exponential-backoff reconnect delay with optional jitter.
    static func reconnectDelay(attempt: Int, configuration: IMAPIdleConfiguration) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 10)
        let multiplier = Double(1 << exponent)
        let baseDelay = min(
            configuration.reconnectBaseDelay * multiplier,
            configuration.reconnectMaxDelay
        )
        let jitterFactor = configuration.reconnectJitterFactor
        guard jitterFactor > 0 else { return baseDelay }
        let jittered = baseDelay * (1 + Double.random(in: -jitterFactor ... jitterFactor))
        return max(0, jittered)
    }
}
