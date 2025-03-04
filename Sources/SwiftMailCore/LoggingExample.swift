import Foundation

/// Example of how to use MailLogger in place of os.log
///
/// Instead of:
/// ```
/// private let logger = Logger(subsystem: "com.cocoanetics.SwiftSMTP", category: "SMTPServer")
/// private let outboundLogger = Logger(subsystem: "com.cocoanetics.SwiftSMTP", category: "SMTP OUT")
/// private let inboundLogger = Logger(subsystem: "com.cocoanetics.SwiftSMTP", category: "SMTP IN")
/// ```
///
/// You can use:
/// ```
/// private let (logger, outboundLogger, inboundLogger) = MailLogger.createLoggers(
///     subsystem: "com.cocoanetics.SwiftSMTP", 
///     protocol: "SMTP"
/// )
/// ```
///
/// Then use the loggers like this:
/// ```
/// logger.debug("Connected to server")
/// outboundLogger.debug("EHLO example.com")
/// inboundLogger.debug("250-STARTTLS")
/// ```
public struct LoggingExample {
    // This is just an example class and doesn't need to be instantiated
    private init() {}
} 