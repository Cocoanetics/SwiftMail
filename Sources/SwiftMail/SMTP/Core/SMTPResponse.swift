// SMTPResponse.swift
// A struct representing an SMTP server response

import Foundation

/**
 A struct representing an SMTP server response
 */
public struct SMTPResponse: Sendable, Equatable {
    /** The response code */
    public let code: Int

    /** The response message */
    public let message: String

    /// Create a response. Public so callers can fabricate replies when
    /// testing retry policies built on ``SMTPSendError``.
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}
