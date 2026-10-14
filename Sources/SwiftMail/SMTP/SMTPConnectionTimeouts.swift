// SMTPConnectionTimeouts.swift
// Configurable timeout budgets for SMTP connection setup.

import Foundation

/// Timeout budgets for setting up an SMTP connection in ``SMTPServer/connect()``.
///
/// The greeting default follows RFC 5321 section 4.5.3.2.1, which recommends
/// waiting five minutes for the initial 220 message; some submission servers
/// delay it while they run anti-abuse checks on a new connection. RFC 5321 gives
/// no values for `EHLO` or `STARTTLS`; their defaults are in the same range as
/// the command timeouts of section 4.5.3.2.
public struct SMTPConnectionTimeouts: Sendable, Equatable {
    /// Maximum time to wait for the server's greeting once the TCP connection
    /// is open. With implicit TLS this includes the TLS handshake.
    public let greeting: TimeInterval

    /// Maximum time to wait for the reply to each `EHLO`, including the one
    /// sent again after `STARTTLS`.
    public let ehloResponse: TimeInterval

    /// Maximum time to wait for the reply to `STARTTLS`.
    public let startTLSResponse: TimeInterval

    /// Creates SMTP connection timeout budgets, expressed in seconds.
    public init(
        greeting: TimeInterval = 5 * 60,
        ehloResponse: TimeInterval = 5 * 60,
        startTLSResponse: TimeInterval = 2 * 60
    ) {
        let maximumNanosecondInterval = TimeInterval(Int64.max / 1_000_000_000)
        let values = [
            greeting,
            ehloResponse,
            startTLSResponse
        ]
        precondition(
            values.allSatisfy {
                $0.isFinite && $0 > 0 && $0 <= maximumNanosecondInterval
            },
            "SMTP connection timeouts must be positive finite nanosecond intervals"
        )

        self.greeting = greeting
        self.ehloResponse = ehloResponse
        self.startTLSResponse = startTLSResponse
    }
}
