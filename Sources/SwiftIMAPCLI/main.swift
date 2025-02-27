// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import SwiftIMAP
import os.log
import SwiftDotenv

// Create a logger for the main application
let logger = Logger(subsystem: "com.cocoanetics.SwiftIMAP", category: "Main")

// Path to the .env file (hardcoded as requested)
let envFilePath = "/Users/oliver/Developer/.env"

do {
    // Configure SwiftDotenv with the specified path
    try Dotenv.configure(atPath: envFilePath)
    
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
            
            // Select the INBOX mailbox and get mailbox information
            let mailboxInfo = try await server.selectMailbox("INBOX")
            
            // Display mailbox information
            let mailboxSummary = """
            📬 Mailbox Information 📬
            ------------------------
            Mailbox: \(mailboxInfo.name)
            Total Messages: \(mailboxInfo.messageCount)
            Recent Messages: \(mailboxInfo.recentCount)
            Unseen Messages: \(mailboxInfo.unseenCount)
            First Unseen Message: \(mailboxInfo.firstUnseen > 0 ? String(mailboxInfo.firstUnseen) : "N/A")
            UID Validity: \(mailboxInfo.uidValidity)
            Next UID: \(mailboxInfo.uidNext)
            Read-Only: \(mailboxInfo.isReadOnly ? "Yes" : "No")
            Available Flags: \(mailboxInfo.availableFlags.joined(separator: ", "))
            Permanent Flags: \(mailboxInfo.permanentFlags.joined(separator: ", "))
            """
            
            logger.notice("\(mailboxSummary, privacy: .public)")
            print(mailboxSummary)
            
            // Fetch the 10 latest complete emails including attachments
            if mailboxInfo.messageCount > 0 {
                logger.notice("Fetching the 10 latest emails with all parts and attachments...")
                
                // Create a SequenceNumberSet for the latest messages
                let startMessage = max(1, mailboxInfo.messageCount - 9)
                let endMessage = mailboxInfo.messageCount
				let sequenceSet = SequenceNumberSet(startMessage...endMessage)

                do {
                    // Use the fetchEmails method with the sequence number set
                    let emails = try await server.fetchEmails(using: sequenceSet)
                    
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
            try await server.close()
        } catch {
            logger.error("Error: \(error.localizedDescription)")
            exit(1)
        }
    }.value
    
} catch {
    logger.error("Error: \(error.localizedDescription)")
    exit(1)
}
