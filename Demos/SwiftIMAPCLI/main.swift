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
    let osLogger = OSLog(subsystem: "com.cocoanetics.SwiftIMAPCLI", category: category)
    
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
let logger = Logger(label: "com.cocoanetics.SwiftIMAPCLI.Main")

print("📧 SwiftIMAPCLI - Email Reading Test")

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
    
    // Create an IMAP server instance
    let server = IMAPServer(host: host, port: port)
    
    // Use Task with await for async operations
    await Task {
        do {
            // Connect to the server
            try await server.connect()
            
            // Login with credentials
            try await server.login(username: username, password: password)
			
            // Detect standard folders
            let detectedConfig = try await server.detectStandardFolders()
            
            // Print detected folder configuration
            print("\n📁 Detected Standard Folders:")
            print("Trash:   \(detectedConfig.trash)")
            print("Archive: \(detectedConfig.archive)")
            print("Sent:    \(detectedConfig.sent)")
            print("Drafts:  \(detectedConfig.drafts)")
            print("Junk:    \(detectedConfig.junk)")
            print("")
            
            // Select the INBOX mailbox and get mailbox information
            let mailboxStatus = try await server.selectMailbox("INBOX")
			
            // Print mailbox information
            if mailboxStatus.messageCount > 0 {
                // Fetch the 10 latest complete emails including attachments
                
				let startMessage = SequenceNumber(max(1, mailboxStatus.messageCount - 9))
				let endMessage = SequenceNumber(mailboxStatus.messageCount)

                do {
                    // Use the fetchEmails method with the sequence number set
                    let emails = try await server.fetchMessages(using: SequenceNumberSet(startMessage...endMessage))
                    
                    print("\n📧 Latest Complete Emails (\(emails.count)) 📧")
                    
                    // Display emails using the improved debug description format
                    for (index, email) in emails.enumerated() {
                        print("\n[\(index + 1)/\(emails.count)] \(email.debugDescription)")
                        print("---")
                    }
                    
                } catch {
                    print("Failed to fetch emails: \(error.localizedDescription)")
                }
            } else {
                print("No messages in mailbox")
            }
            
            // Logout from the server
            try await server.logout()
            
            // Close the connection
            try await server.disconnect()
        }
		catch {
            logger.error("Error: \(error.localizedDescription)")
            exit(1)
        }
    }.value
    
} catch {
    logger.error("Error: \(error.localizedDescription)")
    exit(1)
}
