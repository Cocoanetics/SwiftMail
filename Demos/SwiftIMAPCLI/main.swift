// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import Logging
import SwiftDotenv
import SwiftMail

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

print("📧 SwiftIMAPCLI - Simple Email Demo")

do {
    // Load environment variables
    try Dotenv.configure()
    
    // Get IMAP credentials
    guard case let .string(host) = Dotenv["IMAP_HOST"],
          case let .integer(port) = Dotenv["IMAP_PORT"],
          case let .string(username) = Dotenv["IMAP_USERNAME"],
          case let .string(password) = Dotenv["IMAP_PASSWORD"] else {
        print("❌ Missing or invalid IMAP credentials in .env file")
        exit(1)
    }
    
    print("Connecting to \(host):\(port) as \(username)...")
    
    // Create an IMAP server instance and connect
    let server = IMAPServer(host: host, port: port)
    
    try await server.connect()
    try await server.login(username: username, password: password)
    print("✅ Connected and logged in successfully")
    
    // List special folders and find inbox
    let specialFolders = try await server.listSpecialUseMailboxes()
    guard let inbox = specialFolders.inbox else {
        print("❌ INBOX mailbox not found")
        exit(1)
    }
    
    // Get unseen count without selecting the mailbox (STATUS)
    do {
        let status = try await server.mailboxStatus(inbox.name)
        print("\(inbox.name) status:")
        if let messageCount = status.messageCount {
            print("  - messageCount: \(messageCount)")
        }
        if let unseen = status.unseenCount {
            print("  - unseenCount: \(unseen)")
        }
        if let recent = status.recentCount {
            print("  - recentCount: \(recent)")
        }
        if let size = status.size {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            formatter.includesUnit = true
            formatter.isAdaptive = true
            let niceSize = formatter.string(fromByteCount: Int64(size))
            print("  - size: \(niceSize)")
        }
    } catch {
        print("❌ Error fetching unseen count: \(error)")
    }

    // Select the INBOX mailbox
    print("\nSelecting INBOX...")
    let mailboxStatus = try await server.selectMailbox(inbox.name)
    print("Selected mailbox: \(inbox.name) with \(mailboxStatus.messageCount) messages")
    
    print("\nSearching for invoices with PDF ...")
    do {
        let messagesSet: MessageIdentifierSet<UID> = try await server.search(criteria: [.subject("invoice"), .text(".pdf")])
        print("Found \(messagesSet.count) messages")
        
        if !messagesSet.isEmpty {
            // Fetch and display message headers
            let messageInfos = try await server.fetchMessageInfo(using: messagesSet)
            
            print("\n📧 Invoice Emails (\(messageInfos.count)) 📧")
            for (index, messageInfo) in messageInfos.enumerated() {
                print("\n[\(index + 1)/\(messageInfos.count)]")
                print("Subject: \(messageInfo.subject ?? "No subject")")
                print("From: \(messageInfo.from ?? "Unknown")")
                print("---")
                
                // here we can get and decode specific parts
                for part in messageInfo.parts {
                    // find an part that's an attached PDF
                    guard part.contentType == "application/pdf" else {
                        continue
                    }

                    // get the body data for the part
                    let data = try await server.fetchAndDecodeMessagePartData(messageInfo: messageInfo, part: part)
                    
                    let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
                    let url = desktopURL.appendingPathComponent(part.suggestedFilename)
                    try data.write(to: url)
                }
            }
        }
    } catch {
        print("❌ Error during search: \(error)")
    }
    
    // Get the latest 5 messages
    print("\nFetching the latest 5 messages...")
    if let latestMessagesSet = mailboxStatus.latest(5) { // Reduced to 5 messages
        do {
            let latestHeaders = try await server.fetchMessageInfo(using: latestMessagesSet)
            
            print("\n📧 Latest Emails (\(latestHeaders.count)) 📧")
            for (index, header) in latestHeaders.enumerated() {
                print("\n[\(index + 1)/\(latestHeaders.count)]")
                print("Subject: \(header.subject ?? "No subject")")
                print("From: \(header.from ?? "Unknown")")
                print("Date: \(header.date?.description ?? "No date")")
                print("---")
            }
        } catch {
            print("❌ Error fetching message headers: \(error)")
            print("⚠️  This might be due to malformed email headers in the mailbox")
        }
    } else {
        print("No messages found in INBOX")
    }
	
	// search for unread message
	print("\nSearching for unread messages...")
	do {
		let unreadMessagesSet: MessageIdentifierSet<SequenceNumber> = try await server.search(criteria: [.unseen])
		print("Found \(unreadMessagesSet.count) unread messages")
	} catch {
		print("❌ Error searching for unread messages: \(error)")
	}
    
	// search for sample emails
	print("\nSearching for sample emails...")
	do {
		let sampleMessagesSet: MessageIdentifierSet<UID> = try await server.search(criteria: [.subject("SwiftSMTPCLI")])
		print("Found \(sampleMessagesSet.count) sample emails")
	} catch {
		print("❌ Error searching for sample emails: \(error)")
	}
	
    // Disconnect from the server
    try await server.disconnect()
    print("✅ Successfully disconnected from server")
    
} catch {
    print("❌ Error: \(error.localizedDescription)")
    exit(1)
}
