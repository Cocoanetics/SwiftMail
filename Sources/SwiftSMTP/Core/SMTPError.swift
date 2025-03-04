// SMTPError.swift
// Error types for SMTP operations

import Foundation

/**
 Error types for SMTP operations
 */
public enum SMTPError: Error, LocalizedError {
    case connectionFailed(String)
    case authenticationFailed(String)
    case sendFailed(String)
    case tlsFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return "SMTP connection failed: \(message)"
        case .authenticationFailed(let message):
            return "SMTP authentication failed: \(message)"
        case .sendFailed(let message):
            return "SMTP send failed: \(message)"
        case .tlsFailed(let message):
            return "SMTP TLS negotiation failed: \(message)"
        }
    }
} 