import Foundation

/// Common configuration for mail servers
public struct MailServerConfig {
    /// The server hostname
    public let hostname: String
    
    /// The server port
    public let port: Int
    
    /// Whether to use SSL/TLS
    public let useSSL: Bool
    
    /// Initialize a new mail server configuration
    /// - Parameters:
    ///   - hostname: The server hostname
    ///   - port: The server port
    ///   - useSSL: Whether to use SSL/TLS
    public init(hostname: String, port: Int, useSSL: Bool = true) {
        self.hostname = hostname
        self.port = port
        self.useSSL = useSSL
    }
} 