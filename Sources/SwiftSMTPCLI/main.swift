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
//    // Check if we need verbose logging
//    if ProcessInfo.processInfo.environment["ENABLE_DEBUG_OUTPUT"] == "1" {
        handler.logLevel = .trace
//    } else {
//        handler.logLevel = .info
//    }
    
    return handler
}

// Create a logger for the main application using Swift Logging
let logger = Logger(label: "com.cocoanetics.SwiftSMTP.Main")

// Helper function for debug prints - only prints when ENABLE_DEBUG_OUTPUT is set
func debugPrint(_ message: String) {
    if ProcessInfo.processInfo.environment["ENABLE_DEBUG_OUTPUT"] == "1" {
        print("DEBUG: \(message)")
    }
}

print("📧 SwiftSMTPCLI - Email Sending Test")
print("Debug mode: OS_LOG_DISABLE=\(ProcessInfo.processInfo.environment["OS_LOG_DISABLE"] ?? "not set")")
print("Debug mode: OS_ACTIVITY_MODE=\(ProcessInfo.processInfo.environment["OS_ACTIVITY_MODE"] ?? "not set")")
print("Debug mode: SWIFT_LOG_LEVEL=\(ProcessInfo.processInfo.environment["SWIFT_LOG_LEVEL"] ?? "not set")")

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
    
    debugPrint("SMTP configuration: \(host):\(port) with username \(username)")
    
    // Create an SMTP server instance
    let server = SMTPServer(host: host, port: port)
    
    // Use Task with await for async operations
    await Task {
        do {
            // Connect to the server
            print("Connecting to SMTP server...")
            debugPrint("Initiating connection to \(host):\(port)...")

            try await server.connect()
            debugPrint("Connection established successfully")
            
            // Login with credentials
            print("Authenticating...")
            debugPrint("Sending authentication request...")
            let authSuccess = try await server.authenticate(username: username, password: password)
            
            if authSuccess {
                logger.info("Authentication successful")
                debugPrint("Authentication successful")
            } else {
                logger.error("Authentication failed")
                debugPrint("Authentication failed")
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
            debugPrint("Sending email with subject '\(email.subject)'...")
            try await server.sendEmail(email)
            debugPrint("Email transmission complete")

			print("Email sent successfully!")
            
            // Disconnect from the server
            print("Disconnecting...")
            debugPrint("Sending QUIT command...")
            try await server.disconnect()
            debugPrint("Disconnection complete")
			
        } catch {
            print("Error: \(error.localizedDescription)")
            debugPrint("ERROR: \(error)")
            logger.error("Error: \(error.localizedDescription)")
            exit(1)
        }
    }.value
    
} catch {
    print("Error: \(error.localizedDescription)")
    debugPrint("ERROR: \(error)")
    logger.error("Error: \(error.localizedDescription)")
    exit(1)
} 
