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
    
    // Select the INBOX mailbox
    print("\nSelecting INBOX...")
    let mailboxStatus = try await server.selectMailbox(inbox.name)
    print("Selected mailbox: \(inbox.name) with \(mailboxStatus.messageCount) messages")

//	// Search for messages from YouTube
//	let lunaMessagesSet: MessageIdentifierSet<UID> = try await server.search(criteria: [.subject("Luna")])
//	print("Found \(lunaMessagesSet.count) messages from YouTube")
//	
//	let messages = try await server.fetchMessages(using: lunaMessagesSet)
//	
//	let first = messages.first!
//	let text = first.htmlBody ?? "No text body"
	
    // Search for messages from YouTube
    print("\nSearching for messages from YouTube...")
    let youtubeMessagesSet: MessageIdentifierSet<UID> = try await server.search(criteria: [.subject("Invoice")])
    print("Found \(youtubeMessagesSet.count) messages from YouTube")
    
    // Fetch and display YouTube message headers
    if !youtubeMessagesSet.isEmpty {
		let youtubeHeaders = try await server.fetchHeaders(using: youtubeMessagesSet).prefix(1)
		
        print("\n📧 YouTube Emails (\(youtubeHeaders.count)) 📧")
        for (index, header) in youtubeHeaders.enumerated() {
			print("\n[\(index + 1)/\(youtubeHeaders.count)]\n\(header)")
            print("---")
			
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted]
			let data = try encoder.encode(header)
			let string = String(data: data, encoding: .utf8)!
			print(string)
			
			
        }
		
		let first = youtubeHeaders.first!
		
		let parts = try await server.fetchAllMessageParts(identifier: first.uid!)
		
		let second = parts.last!
		
		print("\n\(second.description)")
		
//		let data = second.decodedContent()
//		let url = URL(fileURLWithPath: "/Users/oliver/Desktop/test1.pdf")
//		try data.write(to: url)
		
		//first.getPart([2])
		
		let base64Data = try await server.fetchMessagePart(part: "2", from: first)
		
		if let base64String = String(data: base64Data, encoding: .utf8)
		{
			let normalized = base64String.replacingOccurrences(of: "\r", with: "")
										   .replacingOccurrences(of: "\n", with: "")
			
			if let decodedData = Data(base64Encoded: normalized) {
				let url = URL(fileURLWithPath: "/Users/oliver/Desktop/test2.pdf")
				try decodedData.write(to: url)
			}
			
		}
//			
//
//			
//			
//
//		{
//			
//			try decodedData.write(to: url)
//		}
		
    } else {
        print("No YouTube messages found.")
    }
    
    // Get the latest 5 messages
    print("\nFetching the latest 5 messages...")
    if let latestMessagesSet = mailboxStatus.latest(100) {
        let latestHeaders = try await server.fetchHeaders(using: latestMessagesSet)
        
        print("\n📧 Latest Emails (\(latestHeaders.count)) 📧")
        for (index, header) in latestHeaders.enumerated() {
            print("\n[\(index + 1)/\(latestHeaders.count)]\n\(header)")
            print("---")
        }
    } else {
        print("No messages found in INBOX")
    }
	
	// search for unread message
	print("\nSearching for unread messages...")
	let unreadMessagesSet: MessageIdentifierSet<SequenceNumber> = try await server.search(criteria: [.unseen])
	print("Found \(unreadMessagesSet.count) unread messages")
    
	// search for sample emails
	print("\nSearching for sample emails...")
	let sampleMessagesSet: MessageIdentifierSet<UID> = try await server.search(criteria: [.subject("SwiftSMTPCLI")])
	print("Found \(sampleMessagesSet.count) sample emails")
	
    // Disconnect from the server
    try await server.disconnect()
    print("✅ Successfully disconnected from server")
    
} catch {
    print("❌ Error: \(error.localizedDescription)")
    exit(1)
}
