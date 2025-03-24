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
    
    /// Unexpected response from server
    case unexpectedResponse(SMTPResponse)
}

// Add CustomStringConvertible conformance for better error messages
extension SMTPError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .connectionFailed(let reason):
            return "SMTP connection failed: \(reason)"
        case .invalidResponse(let reason):
            return "SMTP invalid response: \(reason)"
        case .sendFailed(let reason):
            return "SMTP send failed: \(reason)"
        case .authenticationFailed(let reason):
            return "SMTP authentication failed: \(reason)"
        case .commandFailed(let reason):
            return "SMTP command failed: \(reason)"
        case .invalidEmailAddress(let reason):
            return "SMTP invalid email address: \(reason)"
        case .tlsFailed(let reason):
            return "SMTP TLS failed: \(reason)"
        case .unexpectedResponse(let response):
            return "SMTP unexpected response: \(response.code) \(response.message)"
        }
    }
} 