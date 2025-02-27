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
} 