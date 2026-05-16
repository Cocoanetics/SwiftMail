// SMTPError.swift
// Error types for SMTP operations

import Foundation

/**
 Error types for SMTP operations
 */
public enum SMTPError: Error {
    /// Connection to the server failed
    case connectionFailed(String)

    /// Invalid or unexpected response
    case invalidResponse(String)

    /// Failed to send command or data
    case sendFailed(String)

    /// Authentication failed
    case authenticationFailed(String)

    /// Command failed with a specific error message
    case commandFailed(String)

    /// Invalid email address format
    case invalidEmailAddress(String)

    /// TLS negotiation failed
    case tlsFailed(String)

    /// The message exceeds the server-advertised maximum size
    case messageTooLarge(messageSizeOctets: Int, maximumMessageSizeOctets: Int)

    /// Unexpected response from server
    case unexpectedResponse(SMTPResponse)
}

/// LocalizedError so .localizedDescription returns the real message (not just "error N")
extension SMTPError: LocalizedError {
    public var errorDescription: String? {
        description
    }
}

/// Add CustomStringConvertible conformance for better error messages
extension SMTPError: CustomStringConvertible {
    public var description: String {
        switch self {
            case let .connectionFailed(reason):
                "SMTP connection failed: \(reason)"
            case let .invalidResponse(reason):
                "SMTP invalid response: \(reason)"
            case let .sendFailed(reason):
                "SMTP send failed: \(reason)"
            case let .authenticationFailed(reason):
                "SMTP authentication failed: \(reason)"
            case let .commandFailed(reason):
                "SMTP command failed: \(reason)"
            case let .invalidEmailAddress(reason):
                "SMTP invalid email address: \(reason)"
            case let .tlsFailed(reason):
                "SMTP TLS failed: \(reason)"
            case let .messageTooLarge(messageSizeOctets, maximumMessageSizeOctets):
                "SMTP message too large: \(messageSizeOctets) bytes exceeds \(maximumMessageSizeOctets) byte limit"
            case let .unexpectedResponse(response):
                "SMTP unexpected response: \(response.code) \(response.message)"
        }
    }
}
