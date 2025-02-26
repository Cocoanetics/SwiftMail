// IMAPError+CustomStringConvertible.swift
// Extension for IMAPError to conform to CustomStringConvertible

import Foundation

extension IMAPError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .greetingFailed(let reason):
            return "Server greeting failed: \(reason)"
        case .loginFailed(let reason):
            return "Login failed: \(reason)"
        case .selectFailed(let reason):
            return "Select mailbox failed: \(reason)"
        case .logoutFailed(let reason):
            return "Logout failed: \(reason)"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .fetchFailed(let reason):
            return "Fetch failed: \(reason)"
        case .invalidArgument(let reason):
            return "Invalid argument: \(reason)"
        case .timeout:
            return "Operation timed out"
        }
    }
} 