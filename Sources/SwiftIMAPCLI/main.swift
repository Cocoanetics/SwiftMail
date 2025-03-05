// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import SwiftIMAP
import os
import Logging
import SwiftDotenv
import NIOIMAP

// Set default log level to info - will only show important logs
// Per the cursor rules: Use OS_LOG_DISABLE=1 to see log output as needed
LoggingSystem.bootstrap { label in
    // Create an OSLog-based logger
    let category = label.split(separator: ".").last?.description ?? "default"
    let osLogger = OSLog(subsystem: "com.cocoanetics.SwiftIMAP", category: category)
    
    // Set log level to info by default (or trace if verbose logging is enabled)
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
let logger = Logger(label: "com.cocoanetics.SwiftIMAP.Main")

// Helper function for debug prints - only prints when ENABLE_DEBUG_OUTPUT is set
func debugPrint(_ message: String) {
    if ProcessInfo.processInfo.environment["ENABLE_DEBUG_OUTPUT"] == "1" {
        print("DEBUG: \(message)")
    }
}

print("📧 SwiftIMAPCLI - Email Reading Test")
print("Debug mode: OS_LOG_DISABLE=\(ProcessInfo.processInfo.environment["OS_LOG_DISABLE"] ?? "not set")")
print("Debug mode: OS_ACTIVITY_MODE=\(ProcessInfo.processInfo.environment["OS_ACTIVITY_MODE"] ?? "not set")")
print("Debug mode: SWIFT_LOG_LEVEL=\(ProcessInfo.processInfo.environment["SWIFT_LOG_LEVEL"] ?? "not set")")

do {
    // Configure SwiftDotenv with the specified path
    try Dotenv.configure()
    print("Environment configuration loaded successfully")
    
    // Access IMAP credentials using dynamic member lookup with case pattern matching
    guard case let .string(host) = Dotenv["IMAP_HOST"] else {
        logger.error("IMAP_HOST not found in .env file")
        exit(1)
    }
    
    guard case let .integer(port) = Dotenv["IMAP_PORT"] else {
        logger.error("IMAP_PORT not found or invalid in .env file")
        exit(1)
    }
    
    guard case let .string(username) = Dotenv["IMAP_USERNAME"] else {
        logger.error("IMAP_USERNAME not found in .env file")
        exit(1)
    }
    
    guard case let .string(password) = Dotenv["IMAP_PASSWORD"] else {
        logger.error("IMAP_PASSWORD not found in .env file")
        exit(1)
    }
    
    logger.info("IMAP credentials loaded successfully")
    logger.info("Host: \(host)")
    logger.info("Port: \(port)")
    logger.info("Username: \(username)")
    debugPrint("IMAP configuration: \(host):\(port) with username \(username)")
    
    // Create an IMAP server instance
    let server = IMAPServer(host: host, port: port)
    
    // Use Task with await for async operations
    await Task {
        do {
            // Connect to the server
            debugPrint("Connecting to IMAP server \(host):\(port)...")
            try await server.connect()
            debugPrint("Connection established successfully")
            
            // Login with credentials
            debugPrint("Authenticating with username \(username)...")
            try await server.login(username: username, password: password)
            debugPrint("Authentication successful")
			
            // Detect standard folders
            logger.notice("Detecting standard folders...")
            debugPrint("Detecting standard folders...")
            let detectedConfig = try await server.detectStandardFolders()
            debugPrint("Standard folders detected successfully")
            
            // Print detected folder configuration
            print("\n📁 Detected Standard Folders:")
            print("Trash:   \(detectedConfig.trash)")
            print("Archive: \(detectedConfig.archive)")
            print("Sent:    \(detectedConfig.sent)")
            print("Drafts:  \(detectedConfig.drafts)")
            print("Junk:    \(detectedConfig.junk)")
            print("")
            
            // Select the INBOX mailbox and get mailbox information
            debugPrint("Selecting INBOX mailbox...")
            let mailboxStatus = try await server.selectMailbox("INBOX")
            debugPrint("INBOX selected. Message count: \(mailboxStatus.messageCount)")
            
            // Print mailbox information
            if mailboxStatus.messageCount > 0 {
                // Fetch the 10 latest complete emails including attachments
                logger.notice("Fetching latest emails...")
                debugPrint("Fetching latest emails...")
                
				let startMessage = SequenceNumber(max(1, mailboxStatus.messageCount - 9))
				let endMessage = SequenceNumber(mailboxStatus.messageCount)
                debugPrint("Fetching messages from sequence \(startMessage) to \(endMessage)")

                do {
                    // Use the fetchEmails method with the sequence number set
                    let emails = try await server.fetchMessages(using: SequenceNumberSet(startMessage...endMessage))
                    debugPrint("\(emails.count) emails fetched successfully")
                    
                    logger.notice("📧 Latest Complete Emails (\(emails.count)) 📧")
                    print("\n📧 Latest Complete Emails (\(emails.count)) 📧")
                    
                    // Display emails using the improved debug description format
                    for (index, email) in emails.enumerated() {
                        print("\n[\(index + 1)/\(emails.count)] \(email.debugDescription)")
                        print("---")
                    }
                    
                } catch {
                    logger.error("Failed to fetch emails: \(error.localizedDescription)")
                    print("Failed to fetch emails: \(error.localizedDescription)")
                    debugPrint("ERROR: \(error)")
                }
            } else {
                logger.notice("No messages in mailbox")
                print("No messages in mailbox")
            }
            
            // Logout from the server
            debugPrint("Logging out...")
            try await server.logout()
            debugPrint("Logout successful")
            
            // Close the connection
            debugPrint("Disconnecting...")
            try await server.disconnect()
            debugPrint("Disconnection complete")
        }
		catch let error as NIOIMAP.IMAPDecoderError {
			
			let string = String(buffer: error.buffer)
			print(string)
			debugPrint("ERROR: \(error)")
			
		}
		catch {
            logger.error("Error: \(error.localizedDescription)")
            debugPrint("ERROR: \(error)")
            exit(1)
        }
    }.value
    
} catch {
    logger.error("Error: \(error.localizedDescription)")
    debugPrint("ERROR: \(error)")
    exit(1)
}
