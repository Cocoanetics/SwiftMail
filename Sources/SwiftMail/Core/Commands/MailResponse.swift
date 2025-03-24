// MailResponse.swift
// Common response protocols and types for mail operations

import Foundation

/// A protocol representing a response from a mail server
public protocol MailResponse {
    /// Whether this response indicates success
    var isSuccess: Bool { get }
    
    /// A human-readable message describing the response
    var message: String { get }
}

/// Base error type for mail operations
public enum MailError: Error {
    /// Generic command failure
    case commandFailed(String)
    
    /// Invalid or unexpected response from server
    case invalidResponse(String)
    
    /// Authentication error
    case authenticationFailed(String)
    
    /// Connection error
    case connectionError(String)
    
    /// Timeout error
    case timeout(String)
    
    /// General error with a message
    case general(String)
} 