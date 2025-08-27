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

    // --- MULTIPLE IDLE/DONE CYCLES TEST ---
    print("\n🧪 Testing Multiple IDLE/DONE Cycles (3 cycles, 5 seconds each)...")
    
    for cycle in 1...3 {
        print("\n🔄 Starting IDLE Cycle \(cycle)/3...")
        do {
            let idleStream = try await server.idle()
            print("✅ IDLE session \(cycle) started successfully")
            
            let idleTask = Task {
                for await event in idleStream {
                    print("[IDLE \(cycle)] \(event)")
                }
            }
            
            // Wait for 5 seconds, then exit IDLE
            print("⏱️  Waiting 5 seconds for IDLE cycle \(cycle)...")
            try await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            
            print("🛑 Terminating IDLE cycle \(cycle)...")
            try await server.done()
            idleTask.cancel()
            print("✅ IDLE cycle \(cycle) completed successfully")
            
            // Test superfluous DONE calls after each cycle
            print("🧪 Testing superfluous DONE calls...")
            for i in 1...3 {
                print("  📞 Calling done() #\(i) (should be safe)...")
                try await server.done()
                print("  ✅ Superfluous done() #\(i) completed safely")
            }
            
            // Small delay between cycles
            if cycle < 3 {
                print("⏳ Waiting 2 seconds before next cycle...")
                try await Task.sleep(nanoseconds: 2 * 1_000_000_000)
            }
            
        } catch {
            print("❌ Error during IDLE cycle \(cycle): \(error)")
        }
    }
    
    print("\n🎉 All IDLE cycles completed successfully!")
    
    // Test multiple superfluous DONE calls at the end
    print("\n🧪 Testing multiple superfluous DONE calls at the end...")
    for i in 1...5 {
        print("📞 Calling done() #\(i) (no active IDLE session)...")
        try await server.done()
        print("✅ Superfluous done() #\(i) completed safely")
    }
    
    // Test NOOP after all IDLE cycles and superfluous DONE calls
    print("\n📡 Testing NOOP command after all cycles and superfluous DONE calls...")
    do {
        let noopEvents = try await server.noop()
        print("✅ NOOP successful, events: \(noopEvents)")
    } catch {
        print("❌ Error during NOOP: \(error)")
    }
    // --- END MULTIPLE IDLE/DONE CYCLES TEST ---

    print("\nSearching for invoices with PDF ...")
	let messagesSet: MessageIdentifierSet<UID> = try await server.search(criteria: [.subject("invoice"), .text(".pdf")])
    print("Found \(messagesSet.count) messages")
    
    if !messagesSet.isEmpty {
		
		// Fetch and display message headers
		let messageInfos = try await server.fetchMessageInfo(using: messagesSet)
		
        print("\n📧 Invoice Emails (\(messageInfos.count)) 📧")
        for (index, messageInfo) in messageInfos.enumerated() {
			print("\n[\(index + 1)/\(messageInfos.count)]\n\(messageInfo)")
            print("---")
			
			// here we can get and decode specific parts
			for part in messageInfo.parts {

				// find an part that's an attached PDF
				guard part.contentType == "application/pdf" else
				{
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
    
    // Get the latest 5 messages
    print("\nFetching the latest 5 messages...")
    if let latestMessagesSet = mailboxStatus.latest(100) {
        let latestHeaders = try await server.fetchMessageInfo(using: latestMessagesSet)
        
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
