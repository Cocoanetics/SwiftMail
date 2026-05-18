// String+HostnameTests.swift
// Tests for hostname-related String extensions

import Testing
import Foundation
@testable import SwiftMail

@Suite("String Hostname Extensions Tests", .serialized, .timeLimit(.minutes(1)))
struct StringHostnameTests {

    @Test("Local hostname resolution returns valid hostname")
    func localHostname() {
        let hostname = String.localHostname

        // Test that hostname is not empty
        #expect(!hostname.isEmpty, "Hostname should not be empty")

        // Test hostname format
        if hostname.hasPrefix("[") && hostname.hasSuffix("]") {
            // IP address format
            let address = String(hostname.dropFirst().dropLast())
            #expect(isValidIP(address), "Invalid IP address format: \(address)")
        } else {
            // Hostname format - allow fallback values in CI environments
            // Note: In CI environments, fallback values like "localhost" and "swift-mail-client.local" are legitimate
            if hostname == "localhost" || hostname == "swift-mail-client.local" {
                // These fallback values are acceptable in CI/container environments
                // No assertion needed - these are valid fallback values
            } else {
                // Should be a valid hostname format
                #expect(isValidHostname(hostname), "Invalid hostname format: \(hostname)")
            }
        }
    }

    @Test("Local IP address resolution returns valid IP when available")
    func localIPAddress() {
        if let ipAddress = String.localIPAddress {
            // Test that we got a valid IP address
            #expect(isValidIP(ipAddress), "Invalid IP address format: \(ipAddress)")
        }
        // Note: We don't fail if no IP is found, as this might be legitimate in some environments
    }

    // MARK: - Helper Functions

    private func isValidIP(_ address: String) -> Bool {
        // Simple IPv4 validation
        let ipv4Pattern = "^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"

        // Simple IPv6 validation (allows abbreviated format)
        let ipv6Pattern =
            "^(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}"
                + "|([0-9a-fA-F]{1,4}:){1,7}:"
                + "|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}"
                + "|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}"
                + "|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}"
                + "|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}"
                + "|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}"
                + "|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})"
                + "|:((:[0-9a-fA-F]{1,4}){1,7}|:)"
                + "|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]+"
                + "|::(ffff(:0{1,4})?:)?((25[0-5]|(2[0-4]|1?[0-9])?[0-9])\\.){3}"
                + "(25[0-5]|(2[0-4]|1?[0-9])?[0-9])"
                + "|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1?[0-9])?[0-9])\\.){3}"
                + "(25[0-5]|(2[0-4]|1?[0-9])?[0-9]))$"

        let ipv4Regex = makeRegex(ipv4Pattern)
        let ipv6Regex = makeRegex(ipv6Pattern)

        let range = NSRange(address.startIndex..<address.endIndex, in: address)
        return ipv4Regex.firstMatch(in: address, range: range) != nil ||
            ipv6Regex.firstMatch(in: address, range: range) != nil
    }

    private func isValidHostname(_ hostname: String) -> Bool {
        // RFC 1123 strict validation (no underscores)
        let strictPattern =
            "^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\\-]*[a-zA-Z0-9])\\.)*"
                + "([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\\-]*[A-Za-z0-9])$"
        let strictRegex = makeRegex(strictPattern)
        let range = NSRange(hostname.startIndex..<hostname.endIndex, in: hostname)
        if strictRegex.firstMatch(in: hostname, range: range) != nil {
            return true
        }
        // Allow common macOS/mDNS local hostnames which may include underscores
        if hostname.hasSuffix(".local") {
            let relaxedPattern =
                "^(([A-Za-z0-9_]|[A-Za-z0-9_][A-Za-z0-9_\\-]*[A-Za-z0-9_])\\.)*"
                    + "([A-Za-z0-9_]|[A-Za-z0-9_][A-Za-z0-9_\\-]*[A-Za-z0-9_])$"
            let relaxedRegex = makeRegex(relaxedPattern)
            return relaxedRegex.firstMatch(in: hostname, range: range) != nil
        }
        return false
    }

    /// Compile-time-constant regex patterns can't fail at runtime; surface that
    /// invariant via preconditionFailure so the test target doesn't need `try!`.
    private func makeRegex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Failed to compile constant test regex '\(pattern)': \(error)")
        }
    }
}
