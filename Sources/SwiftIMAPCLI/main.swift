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

// Create a logger for the main application
let logger = os.Logger(subsystem: "com.cocoanetics.SwiftIMAP", category: "Main")

// Path to the .env file (hardcoded as requested)
let envFilePath = "/Users/oliver/Developer/.env"

// Helper function to format flags more compactly
func formatFlags(_ flags: [SwiftIMAP.Flag]) -> String {
    return flags.map { flag -> String in
        switch flag {
        case .seen:
            return "\\Seen"
        case .answered:
            return "\\Answered"
        case .flagged:
            return "\\Flagged"
        case .deleted:
            return "\\Deleted"
        case .draft:
            return "\\Draft"
        case .custom(let name):
            return name
        }
    }.joined(separator: ", ")
}

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
    }
}

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
