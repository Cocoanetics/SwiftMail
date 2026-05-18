import Foundation

/// Configuration for resilient IMAP IDLE sessions.
public struct IMAPIdleConfiguration: Sendable {
    /// RFC 2177 recommends re-issuing IDLE at least every 29 minutes.
    /// Default is ~5 minutes (285s) to align with observed Mail.app behavior.
    public var renewalInterval: TimeInterval

    /// Interval between heartbeat checkpoints where DONE + NOOP + re-IDLE occurs.
    /// Default remains 5 minutes, but probes are disabled by default.
    public var noopInterval: TimeInterval

    /// Enables a post-DONE NOOP probe before re-entering IDLE.
    /// Keep this disabled unless provider behavior specifically benefits from it.
    public var postIdleNoopEnabled: Bool

    /// Optional delay between DONE completion and the post-IDLE NOOP probe.
    public var postIdleNoopDelay: TimeInterval

    /// Timeout while waiting for IDLE to terminate after sending DONE.
    public var doneTimeout: TimeInterval

    /// Initial delay used before reconnecting after a connection failure.
    public var reconnectBaseDelay: TimeInterval

    /// Maximum delay for exponential reconnect backoff.
    public var reconnectMaxDelay: TimeInterval

    /// Jitter factor applied to reconnect backoff.
    /// For example, `0.2` means delay is randomized in `[-20%, +20%]`.
    public var reconnectJitterFactor: Double

    public init(
        renewalInterval: TimeInterval = 285,
        noopInterval: TimeInterval = 5 * 60,
        postIdleNoopEnabled: Bool = false,
        postIdleNoopDelay: TimeInterval = 0.5,
        doneTimeout: TimeInterval = 15,
        reconnectBaseDelay: TimeInterval = 1,
        reconnectMaxDelay: TimeInterval = 120,
        reconnectJitterFactor: Double = 0.2
    ) {
        self.renewalInterval = renewalInterval
        self.noopInterval = noopInterval
        self.postIdleNoopEnabled = postIdleNoopEnabled
        self.postIdleNoopDelay = postIdleNoopDelay
        self.doneTimeout = doneTimeout
        self.reconnectBaseDelay = reconnectBaseDelay
        self.reconnectMaxDelay = reconnectMaxDelay
        self.reconnectJitterFactor = reconnectJitterFactor
    }

    /// Default production-ready values for resilient IDLE sessions.
    public static let `default` = IMAPIdleConfiguration()
}

extension IMAPIdleConfiguration {
    func validated() throws -> IMAPIdleConfiguration {
        guard renewalInterval > 0 else {
            throw IMAPError.invalidArgument("IDLE renewalInterval must be greater than 0 seconds")
        }
        guard noopInterval > 0 else {
            throw IMAPError.invalidArgument("IDLE noopInterval must be greater than 0 seconds")
        }
        guard postIdleNoopDelay >= 0 else {
            throw IMAPError.invalidArgument("IDLE postIdleNoopDelay cannot be negative")
        }
        if postIdleNoopEnabled, postIdleNoopDelay > noopInterval {
            throw IMAPError.invalidArgument("IDLE postIdleNoopDelay must be <= noopInterval when NOOP probing is enabled")
        }
        guard doneTimeout > 0 else {
            throw IMAPError.invalidArgument("IDLE doneTimeout must be greater than 0 seconds")
        }
        guard reconnectBaseDelay >= 0 else {
            throw IMAPError.invalidArgument("IDLE reconnectBaseDelay cannot be negative")
        }
        guard reconnectMaxDelay >= reconnectBaseDelay else {
            throw IMAPError.invalidArgument("IDLE reconnectMaxDelay must be >= reconnectBaseDelay")
        }
        guard (0...1).contains(reconnectJitterFactor) else {
            throw IMAPError.invalidArgument("IDLE reconnectJitterFactor must be between 0 and 1")
        }
        return self
    }
}
