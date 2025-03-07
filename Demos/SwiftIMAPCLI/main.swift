import Foundation
import SwiftIMAP
import Logging
import SwiftDotenv
import NIOIMAP

#if canImport(os)
import os
#endif

#if os(Linux)
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    if ProcessInfo.processInfo.environment["ENABLE_DEBUG_OUTPUT"] == "1" {
        handler.logLevel = .trace
    } else {
        handler.logLevel = .info
    }
    return handler
}
#else
LoggingSystem.bootstrap { label in
    let category = label.split(separator: ".").last?.description ?? "default"
    let osLogger = OSLog(subsystem: "com.cocoanetics.SwiftIMAPCLI", category: category)
    var handler = OSLogHandler(label: label, log: osLogger)
    if ProcessInfo.processInfo.environment["ENABLE_DEBUG_OUTPUT"] == "1" {
        handler.logLevel = .trace
    } else {
        handler.logLevel = .info
    }
    return handler
}
#endif

let logger = Logger(label: "com.cocoanetics.SwiftIMAPCLI.Main")

print("📧 SwiftIMAPCLI - Email Reading Test")

do {
    print("🔍 Looking for .env file...")
    do {
        try Dotenv.configure()
        print("✅ Environment configuration loaded successfully")
    } catch {
        print("❌ Failed to load .env file: \(error.localizedDescription)")
        exit(1)
    }

    print("📋 Loaded environment variables:")
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

    let server = IMAPServer(host: host, port: port)

    do {
        try await server.connect()
        try await server.login(username: username, password: password)

        let specialFolders = try await server.listSpecialUseMailboxes()

        print("\nSpecial Folders:")
        for folder in specialFolders {
            print("- \(folder.name)")
        }

        guard let inbox = specialFolders.inbox else {
            fatalError("INBOX mailbox not found")
        }

        let mailboxStatus = try await server.selectMailbox(inbox.name)

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
