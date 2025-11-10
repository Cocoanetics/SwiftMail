// IMAPError.swift
// Custom IMAP errors

import Foundation

/// Errors that can occur during IMAP operations
public enum IMAPError: Error {
    case greetingFailed(String)
    case loginFailed(String)
    case selectFailed(String)
    case logoutFailed(String)
    case fetchFailed(String)
    case connectionFailed(String)
    case timeout
    case invalidArgument(String)
    case emptyIdentifierSet
    case commandFailed(String)
    case createFailed(String)
    case copyFailed(String)
    case storeFailed(String)
    case expungeFailed(String)
    case moveFailed(String)
    case commandNotSupported(String)
    case authFailed(String)
    case unsupportedAuthMechanism(String)
}

// Add CustomStringConvertible conformance for better error messages
extension IMAPError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .loginFailed(let reason):
            return "Login failed: \(reason)"
        case .selectFailed(let reason):
            return "Select mailbox failed: \(reason)"
        case .fetchFailed(let reason):
            return "Fetch failed: \(reason)"
        case .logoutFailed(let reason):
            return "Logout failed: \(reason)"
        case .timeout:
            return "Operation timed out"
        case .greetingFailed(let reason):
            return "Greeting failed: \(reason)"
        case .invalidArgument(let reason):
            return "Invalid argument: \(reason)"
        case .emptyIdentifierSet:
            return "Empty identifier set provided"
        case .commandFailed(let reason):
            return "Command failed: \(reason)"
        case .createFailed(let reason):
            return "Create mailbox failed: \(reason)"
        case .copyFailed(let reason):
            return "Copy failed: \(reason)"
        case .storeFailed(let reason):
            return "Store failed: \(reason)"
        case .expungeFailed(let reason):
            return "Expunge failed: \(reason)"
        case .moveFailed(let reason):
            return "Move failed: \(reason)"
        case .commandNotSupported(let reason):
            return "Command not supported: \(reason)"
        case .authFailed(let reason):
            return "Authentication failed: \(reason)"
        case .unsupportedAuthMechanism(let reason):
            return "Unsupported authentication mechanism: \(reason)"
        }
    }
}

// Add LocalizedError conformance for better error messages in system contexts
extension IMAPError: LocalizedError {
    public var errorDescription: String? {
        return description
    }
    
    public var failureReason: String? {
        switch self {
        case .connectionFailed(let reason):
            return "Could not establish connection to the IMAP server: \(reason)"
        case .loginFailed(let reason):
            return "Authentication with the IMAP server failed: \(reason)"
        case .selectFailed(let reason):
            return "Could not select the requested mailbox: \(reason)"
        case .fetchFailed(let reason):
            return "Failed to fetch messages: \(reason)"
        case .logoutFailed(let reason):
            return "Failed to properly logout: \(reason)"
        case .timeout:
            return "The operation took too long and timed out"
        case .greetingFailed(let reason):
            return "Server did not provide a proper greeting: \(reason)"
        case .invalidArgument(let reason):
            return "An invalid argument was provided: \(reason)"
        case .emptyIdentifierSet:
            return "An empty set of message identifiers was provided"
        case .commandFailed(let reason):
            return "The IMAP command failed to execute: \(reason)"
        case .createFailed(let reason):
            return "Failed to create mailbox: \(reason)"
        case .copyFailed(let reason):
            return "Failed to copy messages: \(reason)"
        case .storeFailed(let reason):
            return "Failed to store flags: \(reason)"
        case .expungeFailed(let reason):
            return "Failed to expunge deleted messages: \(reason)"
        case .moveFailed(let reason):
            return "Failed to move messages: \(reason)"
        case .commandNotSupported(let reason):
            return "The requested command is not supported by the server: \(reason)"
        case .authFailed(let reason):
            return "The IMAP authentication failed: \(reason)"
        case .unsupportedAuthMechanism(let reason):
            return "The server does not support the requested authentication mechanism: \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .connectionFailed:
            return "Check your network connection and server settings."
        case .loginFailed:
            return "Verify your username and password."
        case .selectFailed:
            return "Make sure the mailbox exists and you have permission to access it."
        case .fetchFailed:
            return "Ensure you have selected a mailbox and have valid message identifiers."
        case .timeout:
            return "Try again later when the server might be less busy."
        case .commandFailed(let reason) where reason.contains("not allowed now"):
            return "Make sure to select a mailbox before performing this operation."
        case .commandNotSupported:
            return "This operation may not be supported by your email provider."
        case .authFailed:
            return "Verify your OAuth credentials or request a fresh access token."
        case .unsupportedAuthMechanism:
            return "Check that your email provider supports XOAUTH2 for IMAP connections."
        default:
            return "Check the error details and try again."
        }
    }
}
