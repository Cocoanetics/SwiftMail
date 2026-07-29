// SMTPSendResult.swift
// Successful SMTP submission outcome carrying the server's final reply

import Foundation

/// The outcome of a successful SMTP message submission.
///
/// Returned by ``SMTPServer/sendEmail(_:)`` and ``SMTPServer/sendRawMessage(_:from:to:)``
/// once the server has acknowledged the transmitted message content with a final
/// 2xx reply (RFC 5321 §4.1.1.4). A final 2xx reply means the server accepted
/// responsibility for the message; it does not prove eventual delivery to every
/// recipient's mailbox.
public struct SMTPSendResult: Sendable, Equatable {
    /// The final 2xx reply that acknowledged the message content,
    /// e.g. `250 2.0.0 OK queued as ABC123`.
    public let response: SMTPResponse

    /// Create a send result. Public so callers can fabricate outcomes when
    /// testing their own retry policies.
    public init(response: SMTPResponse) {
        self.response = response
    }
}
