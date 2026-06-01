// String+Hostname.swift
// Hostname and IP-related extensions for String.
//
// Backed by Foundation's portable `ProcessInfo.hostName` and SwiftCross's
// `ProcessInfo.localIPAddress` (which enumerates interfaces with getifaddrs on
// Apple/Linux/Android and uses getsockname on Windows).

import SwiftCross

extension String {
    /// Get the local hostname for EHLO/HELO commands
    /// - Returns: The local hostname
    public static var localHostname: String {
        let hostName = ProcessInfo.processInfo.hostName
        if !hostName.isEmpty {
            return hostName
        }

        // Fall back to a bracketed literal IP address, then a domain-like default.
        if let localIP = String.localIPAddress {
            return "[\(localIP)]"
        }
        return "swift-mail-client.local"
    }

    /// Get the local IP address
    /// - Returns: The local IP address as a string, or nil if not available
    public static var localIPAddress: String? {
        ProcessInfo.processInfo.localIPAddress
    }
}
