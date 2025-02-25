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
            logger.notice("📬 Mailbox Information 📬")
            logger.notice("------------------------")
            logger.notice("Mailbox: \(mailboxInfo.name)")
            logger.notice("Total Messages: \(mailboxInfo.messageCount)")
            logger.notice("Recent Messages: \(mailboxInfo.recentCount)")
            logger.notice("Unseen Messages: \(mailboxInfo.unseenCount)")
            if mailboxInfo.firstUnseen > 0 {
                logger.notice("First Unseen Message: \(mailboxInfo.firstUnseen)")
            }
            logger.notice("UID Validity: \(mailboxInfo.uidValidity)")
            logger.notice("Next UID: \(mailboxInfo.uidNext)")
            logger.notice("Read-Only: \(mailboxInfo.isReadOnly ? "Yes" : "No")")
            
            if !mailboxInfo.availableFlags.isEmpty {
                logger.notice("Available Flags: \(mailboxInfo.availableFlags.joined(separator: ", "))")
            }
            
            if !mailboxInfo.permanentFlags.isEmpty {
                logger.notice("Permanent Flags: \(mailboxInfo.permanentFlags.joined(separator: ", "))")
            }
            
            // Also print to console for direct visibility
            print("\n📬 Mailbox Information 📬")
            print("------------------------")
            print("Mailbox: \(mailboxInfo.name)")
            print("Total Messages: \(mailboxInfo.messageCount)")
            print("Recent Messages: \(mailboxInfo.recentCount)")
            print("Unseen Messages: \(mailboxInfo.unseenCount)")
            if mailboxInfo.firstUnseen > 0 {
                print("First Unseen Message: \(mailboxInfo.firstUnseen)")
            } else {
                print("First Unseen Message: N/A")
            }
            print("UID Validity: \(mailboxInfo.uidValidity)")
            print("Next UID: \(mailboxInfo.uidNext)")
            print("Read-Only: \(mailboxInfo.isReadOnly ? "Yes" : "No")")
            
            if !mailboxInfo.availableFlags.isEmpty {
                print("Available Flags: \(mailboxInfo.availableFlags.joined(separator: ", "))")
            }
            
            if !mailboxInfo.permanentFlags.isEmpty {
                print("Permanent Flags: \(mailboxInfo.permanentFlags.joined(separator: ", "))")
            }
            print()
            
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
