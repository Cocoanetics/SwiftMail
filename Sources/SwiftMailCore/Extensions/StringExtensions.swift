// StringExtensions.swift
// String extensions for the SwiftMailCore library

import Foundation
import os.log
import Darwin

extension String {
    /// Redacts sensitive information that appears after the specified keyword
    /// For example, "A002 LOGIN username password" becomes "A002 LOGIN [credentials redacted]"
    /// or "AUTH PLAIN base64data" becomes "AUTH [credentials redacted]"
    /// - Parameter keyword: The keyword to look for (e.g., "LOGIN" or "AUTH")
    /// - Returns: The redacted string, or the original string if no redaction was needed
    public func redactAfter(_ keyword: String) -> String {
        // Create a regex pattern that matches IMAP commands in both formats:
        // 1. With a tag: tag + command (e.g., "A001 LOGIN")
        // 2. Without a tag: just the command (e.g., "AUTH PLAIN")
        let pattern = "(^\\s*\\w+\\s+\(keyword)\\b|^\\s*\(keyword)\\b)"
        
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let range = NSRange(location: 0, length: self.utf16.count)
            
            // If we find a match, proceed with redaction
            if let match = regex.firstMatch(in: self, options: [], range: range) {
                // Convert the NSRange back to a String.Index range
                guard let keywordRange = Range(match.range, in: self) else {
                    return self
                }
                
                // Find the end of the keyword/command
                let keywordEnd = keywordRange.upperBound
                
                // Check if there's content after the keyword/command
                guard keywordEnd < self.endIndex else {
                    // If the keyword is at the end, return the original string
                    return self
                }
                
                // Create the redacted string: preserve everything up to the keyword/command (inclusive)
                let preservedPart = self[..<keywordEnd]
                
                return "\(preservedPart) [credentials redacted]"
            } else {
                // No match found, return the original string
                return self
            }
        } catch {
            // If regex creation fails, fall back to the simple substring search
            guard let keywordRange = self.range(of: keyword, options: [.caseInsensitive]) else {
                return self
            }
            
            let keywordEnd = keywordRange.upperBound
            
            guard keywordEnd < self.endIndex else {
                return self
            }
            
            let preservedPart = self[..<keywordEnd]
            
            return "\(preservedPart) [credentials redacted]"
        }
    }
    
    /**
     Get the local hostname for EHLO/HELO commands
     - Returns: The local hostname
     */
	public static var localHostname: String {
        // Try to get the actual hostname
#if os(macOS) && !targetEnvironment(macCatalyst)
        // Host is only available on macOS
        if let hostname = Host.current().name {
            return hostname
        }
#else
        // Use ProcessInfo for Apple platforms
        let hostname = ProcessInfo.processInfo.hostName
        if !hostname.isEmpty && hostname != "localhost" {
            return hostname
        }
#endif
        
        // Try to get a local IP address as a fallback
		if let localIP = String.localIPAddress {
            return "[\(localIP)]"
        }
        
        // Use a domain-like format as a last resort
        return "swift-mail-client.local"
    }
    
    /**
     Get the local IP address
     - Returns: The local IP address as a string, or nil if not available
     */
	public static var localIPAddress: String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }
        
        defer {
            freeifaddrs(ifaddr)
        }
        
        // Iterate through linked list of interfaces
        var currentAddr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        var foundAddress: String? = nil
        
        while let addr = currentAddr {
            let interface = addr.pointee
            
            // Check for IPv4 or IPv6 interface
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
                // Check interface name starts with "en" (Ethernet) or "wl" (WiFi)
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("wl") {
                    // Convert interface address to a human readable string
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    
                    // Get address info
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    
                    if let address = String(validatingUTF8: hostname) {
                        foundAddress = address
                        break
                    }
                }
            }
            
            // Move to next interface
            currentAddr = interface.ifa_next
        }
        
        return foundAddress
    }
} 
