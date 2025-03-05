// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import SwiftSMTP
import os
import Logging
import SwiftDotenv

// Set default log level to info - will only show important logs
// Per the cursor rules: Use OS_LOG_DISABLE=1 to see log output as needed
LoggingSystem.bootstrap { label in
    // Create an OSLog-based logger
    let category = label.split(separator: ".").last?.description ?? "default"
    let osLogger = OSLog(subsystem: "com.cocoanetics.SwiftSMTP", category: category)
    
    // Set log level to info by default (or trace if SWIFT_LOG_LEVEL is set to trace)
    var handler = OSLogHandler(label: label, log: osLogger)

	// Check if we need verbose logging
    if ProcessInfo.processInfo.environment["ENABLE_DEBUG_OUTPUT"] == "1" {
        handler.logLevel = .trace
    } else {
        handler.logLevel = .info
    }
    
    return handler
}

// Create a logger for the main application using Swift Logging
let logger = Logger(label: "com.cocoanetics.SwiftSMTP.Main")

print("📧 SwiftSMTPCLI - Email Sending Test")

do {
    // Configure SwiftDotenv with the specified path
    try Dotenv.configure()
    logger.info("Environment configuration loaded successfully")
    print("Environment configuration loaded successfully")
    
    // Access SMTP credentials using dynamic member lookup with case pattern matching
    guard case let .string(host) = Dotenv["SMTP_HOST"] else {
        logger.error("SMTP_HOST not found in .env file")
        exit(1)
    }
    
    guard case let .integer(port) = Dotenv["SMTP_PORT"] else {
        logger.error("SMTP_PORT not found or invalid in .env file")
        exit(1)
    }
    
    guard case let .string(username) = Dotenv["SMTP_USERNAME"] else {
        logger.error("SMTP_USERNAME not found in .env file")
        exit(1)
    }
    
    guard case let .string(password) = Dotenv["SMTP_PASSWORD"] else {
        logger.error("SMTP_PASSWORD not found in .env file")
        exit(1)
    }
    
    // Create an SMTP server instance
    let server = SMTPServer(host: host, port: port)
    
    // Use Task with await for async operations
    await Task {
        do {
            // Connect to the server
            print("Connecting to SMTP server...")

            try await server.connect()
            
            // Login with credentials
            print("Authenticating...")

			let authSuccess = try await server.authenticate(username: username, password: password)
            
            if authSuccess {
                logger.info("Authentication successful")
            } else {
                logger.error("Authentication failed")
                throw SMTPError.authenticationFailed("Authentication failed")
            }
            
            // Create a test email
            let sender = EmailAddress(name: "Test Sender", address: username)
            let recipient = EmailAddress(name: "Test Recipient", address: username) // Sending to self for testing
            
            let email = Email(
                sender: sender,
                recipients: [recipient],
                subject: "Test Email from SwiftSMTPCLI",
                body: "This is a test email sent from the SwiftSMTPCLI application."
            )
            
            // Send the email
            print("Sending test email to \(recipient.address)...")

			try await server.sendEmail(email)

			print("Email sent successfully!")
            
            // Disconnect from the server
            print("Disconnecting...")

			try await server.disconnect()
        } catch {
            print("Error: \(error.localizedDescription)")
            logger.error("Error: \(error.localizedDescription)")
            exit(1)
        }
    }.value
    
} catch {
    print("Error: \(error.localizedDescription)")
    logger.error("Error: \(error.localizedDescription)")
    exit(1)
} 
