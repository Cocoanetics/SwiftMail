// SwiftIMAP.swift
// Main entry point for the SwiftIMAP library

import Foundation

/// SwiftIMAP is a Swift library for interacting with IMAP servers.
/// It provides a simple, modern API for connecting to IMAP servers,
/// authenticating, and retrieving email messages.
public struct SwiftIMAP {
    /// The version of the SwiftIMAP library
    public static let version = "1.0.0"
    
    /// Returns information about the library
    public static func info() -> String {
        return "SwiftIMAP v\(version) - A Swift library for IMAP email access"
    }
}

// No type aliases needed - we'll use direct naming 