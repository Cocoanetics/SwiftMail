// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import Logging
import SwiftDotenv
import NIOIMAP
import SwiftIMAP

#if canImport(OSLog)

import OSLog

// Set default log level to info - will only show important logs
// Per the cursor rules: Use OS_LOG_DISABLE=1 to see log output as needed
LoggingSystem.bootstrap { label in
	// Create an OSLog-based logger
	let category = label.split(separator: ".").last?.description ?? "default"
	let osLogger = OSLog(subsystem: "com.cocoanetics.SwiftIMAPCLI", category: category)
	
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

#endif

// Create a logger for the main application using Swift Logging
let logger = Logger(label: "com.cocoanetics.SwiftIMAPCLI.Main")

print("📧 SwiftIMAPCLI - Email Reading Test")

do {
    // Configure SwiftDotenv with the specified path
    print("🔍 Looking for .env file...")
    
    // Try loading the .env file
    do {
        try Dotenv.configure()
        print("✅ Environment configuration loaded successfully")
    } catch {
        print("❌ Failed to load .env file: \(error.localizedDescription)")
        exit(1)
    }
    
    // Print the loaded variables to verify
    print("📋 Loaded environment variables:")
    
    // Access IMAP credentials using dynamic member lookup with case pattern matching
    guard case let .string(host) = Dotenv["IMAP_HOST"] else {
        print("❌ IMAP_HOST not found in .env file")
        logger.error("IMAP_HOST not found in .env file")
        exit(1)
    }
    
    print("   IMAP_HOST: \(host)")
    
    guard case let .integer(port) = Dotenv["IMAP_PORT"] else {
        print("❌ IMAP_PORT not found or invalid in .env file")
        logger.error("IMAP_PORT not found or invalid in .env file")
        exit(1)
    }
    
    print("   IMAP_PORT: \(port)")
    
    guard case let .string(username) = Dotenv["IMAP_USERNAME"] else {
        print("❌ IMAP_USERNAME not found in .env file")
        logger.error("IMAP_USERNAME not found in .env file")
        exit(1)
    }
    
    print("   IMAP_USERNAME: \(username)")
    
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
    
	do {
		try await server.connect()
		try await server.login(username: username, password: password)
		
		// List special folders
		let specialFolders = try await server.listSpecialUseMailboxes()
		
		// Display special folders
		print("\nSpecial Folders:")
		for folder in specialFolders {
			print("- \(folder.name)")
		}
		
		guard let inbox = specialFolders.inbox else {
			fatalError("INBOX mailbox not found")
		}
		
		// Select the INBOX mailbox and get mailbox information
		let mailboxStatus = try await server.selectMailbox(inbox.name)
		
		// Use the convenience method to get the latest 10 messages
		if let latestMessagesSet = mailboxStatus.latest(10) {
			let emails = try await server.fetchMessages(using: latestMessagesSet)
			
			print("\n📧 Latest Emails (\(emails.count)) 📧")
			
			for (index, email) in emails.enumerated() {
				print("\n[\(index + 1)/\(emails.count)] \(email.debugDescription)")
				print("---")
			}
		} else {
			print("No messages found in INBOX")
		}
		
		try await server.disconnect()
	} catch {
		logger.error("Error: \(error.localizedDescription)")
		exit(1)
	}
}
