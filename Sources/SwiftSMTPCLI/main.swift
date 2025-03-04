// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import SwiftSMTP
import os
import Logging
import SwiftDotenv

print("Starting SwiftSMTPCLI...")

// Configure the Swift Logging system to use OSLog
LoggingSystem.bootstrap { label in
    // Create an OSLog-based logger
    let category = label.split(separator: ".").last?.description ?? "default"
    let osLogger = OSLog(subsystem: "com.cocoanetics.SwiftSMTP", category: category)
    
    // Return a custom LogHandler that bridges to OSLog
    return OSLogHandler(label: label, log: osLogger)
}

// Create a logger for the main application
let logger = os.Logger(subsystem: "com.cocoanetics.SwiftSMTP", category: "Main")

// Path to the .env file (hardcoded as requested)
let envFilePath = "/Users/oliver/Developer/.env"

print("Using .env file at: \(envFilePath)")

// Custom LogHandler that bridges Swift Logging to OSLog
struct OSLogHandler: LogHandler {
    let label: String
    let log: OSLog
    
    // Required property for LogHandler protocol
    var logLevel: Logging.Logger.Level = .debug  // Set to debug to capture all logs
    
    // Required property for LogHandler protocol
    var metadata = Logging.Logger.Metadata()
    
    // Required subscript for LogHandler protocol
    subscript(metadataKey metadataKey: String) -> Logging.Logger.Metadata.Value? {
        get {
            return metadata[metadataKey]
        }
        set {
            metadata[metadataKey] = newValue
        }
    }
    
    // Initialize with a label and OSLog instance
    init(label: String, log: OSLog) {
        self.label = label
        self.log = log
    }
    
    // Required method for LogHandler protocol
    func log(level: Logging.Logger.Level, message: Logging.Logger.Message, metadata: Logging.Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        // Map Swift Logging levels to OSLog types
        let type: OSLogType
        switch level {
        case .trace, .debug:
            type = .debug
        case .info, .notice:
            type = .info
        case .warning:
            type = .default
        case .error:
            type = .error
        case .critical:
            type = .fault
        }
        
        // Log the message using OSLog
        os_log("%{public}@", log: log, type: type, message.description)
        
        // Also print to console for debugging
        print("[\(level)] \(message.description)")
    }
}

do {
    print("Configuring SwiftDotenv...")
    // Configure SwiftDotenv with the specified path
    try Dotenv.configure(atPath: envFilePath)
    
    print("Reading SMTP credentials from .env file...")
    // Access SMTP credentials using dynamic member lookup with case pattern matching
    guard case let .string(host) = Dotenv["SMTP_HOST"] else {
        print("Error: SMTP_HOST not found in .env file")
        logger.error("SMTP_HOST not found in .env file")
        exit(1)
    }
    
    guard case let .integer(port) = Dotenv["SMTP_PORT"] else {
        print("Error: SMTP_PORT not found or invalid in .env file")
        logger.error("SMTP_PORT not found or invalid in .env file")
        exit(1)
    }
    
    guard case let .string(username) = Dotenv["SMTP_USERNAME"] else {
        print("Error: SMTP_USERNAME not found in .env file")
        logger.error("SMTP_USERNAME not found in .env file")
        exit(1)
    }
    
    guard case let .string(password) = Dotenv["SMTP_PASSWORD"] else {
        print("Error: SMTP_PASSWORD not found in .env file")
        logger.error("SMTP_PASSWORD not found in .env file")
        exit(1)
    }
    
    print("SMTP credentials loaded successfully")
    print("Host: \(host)")
    print("Port: \(port)")
    print("Username: \(username)")
    
    logger.info("SMTP credentials loaded successfully")
    logger.info("Host: \(host)")
    logger.info("Port: \(port)")
    logger.info("Username: \(username)")
    
    print("Creating SMTPServer instance...")
    // Create an SMTP server instance
    let server = SMTPServer(host: host, port: port)
    
    print("Starting async task...")
    // Use Task with await for async operations
    await Task {
        do {
            print("Connecting to SMTP server...")
            // Connect to the server
            try await server.connect()
            
            print("Authenticating with SMTP server...")
            // Login with credentials
            try await server.authenticate(username: username, password: password)
            
            print("Creating test email...")
            // Create a test email
            let sender = EmailAddress(name: "Test Sender", address: username)
            let recipient = EmailAddress(name: "Test Recipient", address: username) // Sending to self for testing
            
            let email = Email(
                sender: sender,
                recipients: [recipient],
                subject: "Test Email from SwiftSMTPCLI",
                body: "This is a test email sent from the SwiftSMTPCLI application."
            )
            
            print("Sending test email...")
            // Send the email
            logger.notice("Sending test email...")
            try await server.sendEmail(email)
            
            print("Email sent successfully!")
            logger.notice("📧 Email sent successfully!")
            print("\n📧 Email sent successfully!")
            print("From: \(email.sender.formatted)")
            print("To: \(email.recipients.map { $0.formatted }.joined(separator: ", "))")
            print("Subject: \(email.subject)")
            print("Body: \(email.body)")
            
            print("Disconnecting from SMTP server...")
            // Disconnect from the server
            try await server.disconnect()
            
        } catch {
            print("Error: \(error)")
            print("Detailed error: \(error.localizedDescription)")
            logger.error("Error: \(error.localizedDescription)")
            exit(1)
        }
    }.value
    
} catch {
    print("Error: \(error)")
    print("Detailed error: \(error.localizedDescription)")
    logger.error("Error: \(error.localizedDescription)")
    exit(1)
} 