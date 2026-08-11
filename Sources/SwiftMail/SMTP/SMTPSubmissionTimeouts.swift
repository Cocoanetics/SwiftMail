// SMTPSubmissionTimeouts.swift
// Configurable timeout budgets for the SMTP mail-submission dialogue.

import Foundation

/// Timeout budgets for one SMTP mail-submission transaction.
///
/// The defaults follow the recommendations in RFC 5321 section 4.5.3.2:
/// five minutes for `MAIL FROM` and each `RCPT TO`, two minutes for `DATA`,
/// three minutes for each message-content buffer, and ten minutes for the final
/// reply after the content terminator has been flushed.
public struct SMTPSubmissionTimeouts: Sendable, Equatable {
    /// Maximum time to wait for the reply to `MAIL FROM`.
    public let mailFromResponse: TimeInterval

    /// Maximum time to wait for the reply to each `RCPT TO`.
    public let recipientResponse: TimeInterval

    /// Maximum time to wait for the reply to `DATA`.
    public let dataResponse: TimeInterval

    /// Maximum time to flush each message-content buffer. SwiftMail sends
    /// content in bounded buffers and starts a fresh budget after each
    /// successful flush, including for the buffer with the terminating dot.
    public let contentUpload: TimeInterval

    /// Maximum time to wait for the final acceptance reply after upload.
    public let contentResponse: TimeInterval

    /// Creates SMTP submission timeout budgets, expressed in seconds.
    public init(
        mailFromResponse: TimeInterval = 5 * 60,
        recipientResponse: TimeInterval = 5 * 60,
        dataResponse: TimeInterval = 2 * 60,
        contentUpload: TimeInterval = 3 * 60,
        contentResponse: TimeInterval = 10 * 60
    ) {
        let maximumNanosecondInterval = TimeInterval(Int64.max / 1_000_000_000)
        let values = [
            mailFromResponse,
            recipientResponse,
            dataResponse,
            contentUpload,
            contentResponse
        ]
        precondition(
            values.allSatisfy {
                $0.isFinite && $0 > 0 && $0 <= maximumNanosecondInterval
            },
            "SMTP submission timeouts must be positive finite nanosecond intervals"
        )

        self.mailFromResponse = mailFromResponse
        self.recipientResponse = recipientResponse
        self.dataResponse = dataResponse
        self.contentUpload = contentUpload
        self.contentResponse = contentResponse
    }
}
