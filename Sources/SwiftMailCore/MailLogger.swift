import Foundation
import Logging

/// A simple logger for mail operations
public struct MailLogger {
    private let logger: Logger
    
    /// Initialize a new mail logger
    /// - Parameters:
    ///   - subsystem: The subsystem identifier (e.g., "com.cocoanetics.SwiftSMTP")
    ///   - category: The category for log messages (e.g., "SMTP", "SMTP OUT", "SMTP IN")
    public init(subsystem: String, category: String) {
        var logger = Logger(label: "\(subsystem).\(category)")
        logger.logLevel = .debug
        self.logger = logger
    }
    
    /// Log a debug message
    /// - Parameter message: The message to log
    public func debug(_ message: @autoclosure () -> String) {
        logger.debug("\(message())")
    }
    
    /// Log an info message
    /// - Parameter message: The message to log
    public func info(_ message: @autoclosure () -> String) {
        logger.info("\(message())")
    }
    
    /// Log a warning message
    /// - Parameter message: The message to log
    public func warning(_ message: @autoclosure () -> String) {
        logger.warning("\(message())")
    }
    
    /// Log an error message
    /// - Parameter message: The message to log
    public func error(_ message: @autoclosure () -> String) {
        logger.error("\(message())")
    }
    
    /// Log a critical error message
    /// - Parameter message: The message to log
    public func critical(_ message: @autoclosure () -> String) {
        logger.critical("\(message())")
    }
    
    /// Factory method to create a set of loggers for mail protocols
    /// - Parameters:
    ///   - subsystem: The subsystem identifier (e.g., "com.cocoanetics.SwiftSMTP")
    ///   - protocol: The protocol name (e.g., "SMTP", "IMAP")
    /// - Returns: A tuple containing the main, outbound, and inbound loggers
    public static func createLoggers(subsystem: String, protocol: String) -> (main: MailLogger, outbound: MailLogger, inbound: MailLogger) {
        let main = MailLogger(subsystem: subsystem, category: `protocol`)
        let outbound = MailLogger(subsystem: subsystem, category: "\(`protocol`) OUT")
        let inbound = MailLogger(subsystem: subsystem, category: "\(`protocol`) IN")
        return (main, outbound, inbound)
    }
} 