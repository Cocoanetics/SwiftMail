// Common.swift
// Common utilities shared between IMAP and SMTP modules

import Foundation
import NIO
import NIOSSL

/// Email address representation
public struct EmailAddress: Hashable, Codable {
    /// The name part of the address (optional)
    public let name: String?
    
    /// The email address
    public let address: String
    
    /// Initialize a new email address
    /// - Parameters:
    ///   - name: Optional display name
    ///   - address: The email address
    public init(name: String? = nil, address: String) {
        self.name = name
        self.address = address
    }
    
    /// Format the email address as per RFC 5322
    public var formatted: String {
        if let name = name, !name.isEmpty {
            // Use quotes if the name contains special characters
            if name.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) {
                return "\"\(name)\" <\(address)>"
            } else {
                return "\(name) <\(address)>"
            }
        } else {
            return address
        }
    }
}

/// Common SSL/TLS configuration helpers for mail protocols
public enum MailSSLConfiguration {
    /// Create a standard SSL configuration for mail services
    /// - Parameter hostname: The server hostname
    /// - Returns: NIO SSL context
    public static func createSSLContext(hostname: String) throws -> NIOSSLContext {
        let configuration = TLSConfiguration.makeClientConfiguration()
        return try NIOSSLContext(configuration: configuration)
    }
}

/// Logging categories for mail operations
public struct MailLogCategory {
    public static let imap = "IMAP"
    public static let smtp = "SMTP"
    public static let imapOut = "IMAP OUT"
    public static let imapIn = "IMAP IN"
    public static let smtpOut = "SMTP OUT"
    public static let smtpIn = "SMTP IN"
} 