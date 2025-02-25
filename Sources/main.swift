// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import os.log
import SwiftDotenv
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOSSL

// Create a logger for the main application
let logger = Logger(subsystem: "com.example.SwiftIMAP", category: "Main")

// Log messages at different levels to demonstrate how they appear in Console.app
logger.notice("🚀 SwiftIMAP - IMAP Client Starting Up 🚀")
logger.debug("Debug level message - detailed information for debugging")
logger.info("Info level message - general information about program execution")
logger.notice("Notice level message - important information that should be visible by default")
logger.warning("Warning level message - potential issues that aren't errors")
logger.error("Error level message - errors that don't prevent the app from running")
logger.critical("Critical level message - critical errors that may prevent the app from running")

logger.info("SwiftIMAP - IMAP Client using .env credentials")
logger.info("----------------------------------------------")

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
    
    // Use async/await with a Task
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
            print("\n\(mailboxSummary)")
            
            // Fetch headers of unseen messages
            if mailboxInfo.unseenCount > 0 && mailboxInfo.firstUnseen > 0 {
                logger.notice("Fetching headers of unseen messages...")
                
                // Create a range string for unseen messages
                // If there are too many unseen messages, limit to the first 10
                let maxUnseenToFetch = min(mailboxInfo.unseenCount, 10)
                let lastUnseen = mailboxInfo.firstUnseen + maxUnseenToFetch - 1
                let unseenRange = "\(mailboxInfo.firstUnseen):\(lastUnseen)"
                
                do {
                    let headers = try await server.fetchHeaders(range: unseenRange)
                    
                    logger.notice("📧 Unseen Messages (\(headers.count)) 📧")
                    print("\n📧 Unseen Messages (\(headers.count)) 📧")
                    print("----------------------------")
                    
                    for header in headers {
                        let headerSummary = """
                        Message #\(header.sequenceNumber)
                        Subject: \(header.subject)
                        From: \(header.from)
                        Date: \(header.date)
                        ---
                        """
                        logger.notice("\(headerSummary, privacy: .public)")
                        print(headerSummary)
                    }
                    
                    // Example: Fetch all parts of the first unseen message
                    if let firstHeader = headers.first {
                        logger.notice("Fetching all parts of message #\(firstHeader.sequenceNumber)...")
                        print("\nFetching all parts of message #\(firstHeader.sequenceNumber)...")
                        
                        do {
                            let parts = try await server.fetchAllMessageParts(sequenceNumber: firstHeader.sequenceNumber)
                            
                            logger.notice("Message has \(parts.count) parts")
                            print("Message has \(parts.count) parts")
                            
                            for part in parts {
                                let partSummary = """
                                \(part.description)
                                """
                                logger.notice("\(partSummary, privacy: .public)")
                                print(partSummary)
                                
                                // If this is a text part, display the content
                                if part.contentType.lowercased() == "text" {
                                    if let textContent = String(data: part.data, encoding: .utf8) {
                                        // Limit the text content to 200 characters for display
                                        let limitedContent = textContent.prefix(200)
                                        print("Content preview: \(limitedContent)...")
                                        if textContent.count > 200 {
                                            print("(Content truncated, total length: \(textContent.count) characters)")
                                        }
                                    }
                                }
                                print("---")
                            }
                            
                            // Save all message parts to the desktop
                            logger.notice("Saving message #\(firstHeader.sequenceNumber) parts to desktop...")
                            print("\nSaving message #\(firstHeader.sequenceNumber) parts to desktop...")
                            
                            do {
                                let outputPath = try await server.saveMessagePartsToDesktop(sequenceNumber: firstHeader.sequenceNumber)
                                logger.notice("Message parts saved to: \(outputPath)")
                                print("Message parts saved to: \(outputPath)")
                                print("Open this folder to view all message parts and the index.html file")
                            } catch {
                                logger.error("Failed to save message parts to desktop: \(error.localizedDescription)")
                                print("Failed to save message parts to desktop: \(error.localizedDescription)")
                            }
                        } catch {
                            logger.error("Failed to fetch message parts: \(error.localizedDescription)")
                            print("Failed to fetch message parts: \(error.localizedDescription)")
                        }
                    }
                } catch {
                    logger.error("Failed to fetch headers: \(error.localizedDescription)")
                    print("Failed to fetch headers: \(error.localizedDescription)")
                }
            } else {
                logger.notice("No unseen messages to fetch")
                print("No unseen messages to fetch")
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

// Add a delay to ensure logs are processed and visible in Console.app
logger.notice("Application completed, waiting for logs to be processed...")
try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
logger.notice("Application exiting")
