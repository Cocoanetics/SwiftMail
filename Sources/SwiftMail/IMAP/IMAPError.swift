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
    /// The APPEND payload exceeds the server-advertised APPENDLIMIT.
    ///
    /// Associated values: `(payloadSize, limit)` — both in bytes.
    case appendLimitExceeded(Int, Int)
}

/// Add CustomStringConvertible conformance for better error messages
extension IMAPError: CustomStringConvertible {
    public var description: String {
        switch self {
            case let .connectionFailed(reason):
                "Connection failed: \(reason)"
            case let .loginFailed(reason):
                "Login failed: \(reason)"
            case let .selectFailed(reason):
                "Select mailbox failed: \(reason)"
            case let .fetchFailed(reason):
                "Fetch failed: \(reason)"
            case let .logoutFailed(reason):
                "Logout failed: \(reason)"
            case .timeout:
                "Operation timed out"
            case let .greetingFailed(reason):
                "Greeting failed: \(reason)"
            case let .invalidArgument(reason):
                "Invalid argument: \(reason)"
            case .emptyIdentifierSet:
                "Empty identifier set provided"
            case let .commandFailed(reason):
                "Command failed: \(reason)"
            case let .createFailed(reason):
                "Create mailbox failed: \(reason)"
            case let .copyFailed(reason):
                "Copy failed: \(reason)"
            case let .storeFailed(reason):
                "Store failed: \(reason)"
            case let .expungeFailed(reason):
                "Expunge failed: \(reason)"
            case let .moveFailed(reason):
                "Move failed: \(reason)"
            case let .commandNotSupported(reason):
                "Command not supported: \(reason)"
            case let .authFailed(reason):
                "Authentication failed: \(reason)"
            case let .unsupportedAuthMechanism(reason):
                "Unsupported authentication mechanism: \(reason)"
            case let .appendLimitExceeded(payloadSize, limit):
                "Append payload (\(payloadSize) bytes) exceeds server APPENDLIMIT (\(limit) bytes)"
        }
    }
}

/// Add LocalizedError conformance for better error messages in system contexts
extension IMAPError: LocalizedError {
    public var errorDescription: String? {
        description
    }

    public var failureReason: String? {
        switch self {
            case let .connectionFailed(reason):
                "Could not establish connection to the IMAP server: \(reason)"
            case let .loginFailed(reason):
                "Authentication with the IMAP server failed: \(reason)"
            case let .selectFailed(reason):
                "Could not select the requested mailbox: \(reason)"
            case let .fetchFailed(reason):
                "Failed to fetch messages: \(reason)"
            case let .logoutFailed(reason):
                "Failed to properly logout: \(reason)"
            case .timeout:
                "The operation took too long and timed out"
            case let .greetingFailed(reason):
                "Server did not provide a proper greeting: \(reason)"
            case let .invalidArgument(reason):
                "An invalid argument was provided: \(reason)"
            case .emptyIdentifierSet:
                "An empty set of message identifiers was provided"
            case let .commandFailed(reason):
                "The IMAP command failed to execute: \(reason)"
            case let .createFailed(reason):
                "Failed to create mailbox: \(reason)"
            case let .copyFailed(reason):
                "Failed to copy messages: \(reason)"
            case let .storeFailed(reason):
                "Failed to store flags: \(reason)"
            case let .expungeFailed(reason):
                "Failed to expunge deleted messages: \(reason)"
            case let .moveFailed(reason):
                "Failed to move messages: \(reason)"
            case let .commandNotSupported(reason):
                "The requested command is not supported by the server: \(reason)"
            case let .authFailed(reason):
                "The IMAP authentication failed: \(reason)"
            case let .unsupportedAuthMechanism(reason):
                "The server does not support the requested authentication mechanism: \(reason)"
            case let .appendLimitExceeded(payloadSize, limit):
                "The message (\(payloadSize) bytes) is too large for the server limit of \(limit) bytes"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
            case .connectionFailed:
                "Check your network connection and server settings."
            case .loginFailed:
                "Verify your username and password."
            case .selectFailed:
                "Make sure the mailbox exists and you have permission to access it."
            case .fetchFailed:
                "Ensure you have selected a mailbox and have valid message identifiers."
            case .timeout:
                "Try again later when the server might be less busy."
            case let .commandFailed(reason) where reason.contains("not allowed now"):
                "Make sure to select a mailbox before performing this operation."
            case .commandNotSupported:
                "This operation may not be supported by your email provider."
            case .authFailed:
                "Verify your OAuth credentials or request a fresh access token."
            case .unsupportedAuthMechanism:
                "Check that your email provider supports XOAUTH2 for IMAP connections."
            default:
                "Check the error details and try again."
        }
    }
}
