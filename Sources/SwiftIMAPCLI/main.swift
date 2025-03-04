// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import SwiftIMAP
import os
import Logging
import SwiftDotenv
import NIOIMAP

// Configure the Swift Logging system to use OSLog
LoggingSystem.bootstrap { label in
    // Create an OSLog-based logger
    let category = label.split(separator: ".").last?.description ?? "default"
    let osLogger = OSLog(subsystem: "com.cocoanetics.SwiftIMAP", category: category)
    
    // Return a custom LogHandler that bridges to OSLog
    return OSLogHandler(label: label, log: osLogger)
}

// Create a logger for the main application using Swift Logging
let logger = Logger(label: "com.cocoanetics.SwiftIMAP.Main")

do {
    // Configure SwiftDotenv with the specified path
    try Dotenv.configure()
    
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
			
	//		try await server.fetchCapabilities()
            
            // Detect standard folders
            logger.notice("Detecting standard folders...")
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
                logger.notice("Fetching latest emails...")
                
				let startMessage = SequenceNumber(max(1, mailboxStatus.messageCount - 9))
				let endMessage = SequenceNumber(mailboxStatus.messageCount)

                do {
                    // Use the fetchEmails method with the sequence number set
                    let emails = try await server.fetchMessages(using: SequenceNumberSet(startMessage...endMessage))
                    
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
                }
            } else {
                logger.notice("No messages in mailbox")
                print("No messages in mailbox")
            }
            
            // Logout from the server
            try await server.logout()
            
            // Close the connection
            try await server.disconnect()
        }
		catch let error as NIOIMAP.IMAPDecoderError {
			
			let string = String(buffer: error.buffer)
			print(string)
			
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
