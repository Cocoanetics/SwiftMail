// String+HostnameTests.swift
// Tests for hostname-related String extensions

import XCTest
@testable import SwiftMail

final class StringHostnameTests: XCTestCase {
    func testLocalHostname() {
        let hostname = String.localHostname
        
        // Test that hostname is not empty
        XCTAssertFalse(hostname.isEmpty)
        
        // Test that hostname is not the fallback value unless all other methods fail
        if !hostname.hasPrefix("[") && !hostname.hasSuffix("]") {
            // If it's not an IP address format, it should be a valid hostname
            XCTAssertNotEqual(hostname, "localhost")
            XCTAssertNotEqual(hostname, "swift-mail-client.local")
        }
        
        // Test hostname format
        if hostname.hasPrefix("[") && hostname.hasSuffix("]") {
            // IP address format
            let ip = String(hostname.dropFirst().dropLast())
            XCTAssertTrue(isValidIP(ip), "Invalid IP address format: \(ip)")
        } else {
            // Hostname format
            XCTAssertTrue(isValidHostname(hostname), "Invalid hostname format: \(hostname)")
        }
    }
    
    func testLocalIPAddress() {
        if let ipAddress = String.localIPAddress {
            // Test that we got a valid IP address
            XCTAssertTrue(isValidIP(ipAddress), "Invalid IP address format: \(ipAddress)")
        }
        // Note: We don't fail if no IP is found, as this might be legitimate in some environments
    }
    
    // MARK: - Helper Functions
    
    private func isValidIP(_ ip: String) -> Bool {
        // Simple IPv4 validation
        let ipv4Pattern = "^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
        
        // Simple IPv6 validation (allows abbreviated format)
        let ipv6Pattern = "^(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]+|::(ffff(:0{1,4})?:)?((25[0-5]|(2[0-4]|1?[0-9])?[0-9])\\.){3}(25[0-5]|(2[0-4]|1?[0-9])?[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1?[0-9])?[0-9])\\.){3}(25[0-5]|(2[0-4]|1?[0-9])?[0-9]))$"
        
        let ipv4Regex = try! NSRegularExpression(pattern: ipv4Pattern)
        let ipv6Regex = try! NSRegularExpression(pattern: ipv6Pattern)
        
        let range = NSRange(ip.startIndex..<ip.endIndex, in: ip)
        return ipv4Regex.firstMatch(in: ip, range: range) != nil ||
               ipv6Regex.firstMatch(in: ip, range: range) != nil
    }
    
    private func isValidHostname(_ hostname: String) -> Bool {
        // RFC 1123 hostname validation
        let pattern = "^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\\-]*[a-zA-Z0-9])\\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\\-]*[A-Za-z0-9])$"
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(hostname.startIndex..<hostname.endIndex, in: hostname)
        return regex.firstMatch(in: hostname, range: range) != nil
    }
} 