import Foundation
import ArgumentParser
import Logging
import SwiftDotenv
import SwiftMail

// Setup Logger (silence unless debug)
let logger = Logger(label: "com.cocoanetics.SwiftIMAPCLI")

// Helper to run async code synchronously
func runAsyncBlock(_ block: @escaping () async throws -> Void) {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            try await block()
        } catch {
            print("Error: \(error)")
            exit(1)
        }
        semaphore.signal()
    }
    semaphore.wait()
}

struct IMAPTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "SwiftIMAPCLI",
        abstract: "A CLI for interacting with IMAP servers using SwiftMail.",
        subcommands: [List.self, Fetch.self, Move.self, Idle.self, Search.self]
    )
}

// Helper to manage server lifecycle
func withServer<T>(_ block: (IMAPServer) async throws -> T) async throws -> T {
    try Dotenv.configure()
    
    guard case let .string(host) = Dotenv["IMAP_HOST"],
          case let .integer(port) = Dotenv["IMAP_PORT"],
          case let .string(username) = Dotenv["IMAP_USERNAME"],
          case let .string(password) = Dotenv["IMAP_PASSWORD"] else {
        throw ValidationError("Missing IMAP credentials in .env")
    }
    
    let server = IMAPServer(host: host, port: port)
    try await server.connect()
    try await server.login(username: username, password: password)
    
    do {
        let result = try await block(server)
        try await server.disconnect()
        return result
    } catch {
        try? await server.disconnect()
        throw error
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List emails in INBOX")
    
    @Option(name: .shortAndLong, help: "Number of messages to list")
    var limit: Int = 10
    
    @Option(name: .shortAndLong, help: "Mailbox to list from")
    var mailbox: String = "INBOX"

    func run() throws {
        runAsyncBlock {
            try await withServer { server in
                let status = try await server.selectMailbox(mailbox)
                print("📂 Selected \(mailbox): \(status.messageCount) messages")
                
                guard let latest = status.latest(limit) else {
                    print("No messages found.")
                    return
                }
                
                print("\nfetching \(limit) messages...")
                for try await message in server.fetchMessages(using: latest) {
                    print("[\(message.uid?.value ?? 0)] \(message.date?.description ?? "") - \(message.from ?? "Unknown")")
                    print("   \(message.subject ?? "(No Subject)")")
                }
            }
        }
    }
}

struct Fetch: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Fetch a specific email by UID")
    
    @Argument(help: "UID of the message")
    var uid: Int

    @Option(name: .shortAndLong, help: "Mailbox")
    var mailbox: String = "INBOX"

    func run() throws {
        runAsyncBlock {
            try await withServer { server in
                _ = try await server.selectMailbox(mailbox)
                
                let uids = MessageIdentifierSet<UID>(UID(uid))
                var found = false
                
                for try await message in server.fetchMessages(using: uids) {
                    found = true
                    print("--- Message \(uid) ---")
                    print("From: \(message.from ?? "")")
                    print("Subject: \(message.subject ?? "")")
                    print("Date: \(message.date?.description ?? "")")
                    print("\nBody:")
                    if let text = message.textBody {
                        print(text)
                    } else if let html = message.htmlBody {
                        print("(HTML Body) \(html.prefix(100))...")
                    }
                    
                    if !message.attachments.isEmpty {
                        print("\nAttachments: \(message.attachments.count)")
                        for part in message.attachments {
                            print("- \(part.filename ?? "unnamed") (\(part.contentType))")
                        }
                    }
                }
                
                if !found {
                    print("Message UID \(uid) not found.")
                }
            }
        }
    }
}

struct Move: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Move an email to another folder")
    
    @Argument(help: "UID of the message")
    var uid: Int
    
    @Argument(help: "Target mailbox")
    var target: String

    @Option(name: .shortAndLong, help: "Source Mailbox")
    var mailbox: String = "INBOX"

    func run() throws {
        runAsyncBlock {
            try await withServer { server in
                _ = try await server.selectMailbox(mailbox)
                
                let uids = MessageIdentifierSet<UID>(UID(uid))
                try await server.move(messages: uids, to: target)
                print("Moved UID \(uid) to \(target)")
            }
        }
    }
}

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search emails")
    
    @Argument(help: "Search query (subject)")
    var query: String
    
    @Option(name: .shortAndLong, help: "Mailbox")
    var mailbox: String = "INBOX"

    func run() throws {
        runAsyncBlock {
            try await withServer { server in
                _ = try await server.selectMailbox(mailbox)
                
                let uids: MessageIdentifierSet<UID> = try await server.search(criteria: [.subject(query)])
                print("Found \(uids.count) messages matching '\(query)'")
                
                if !uids.isEmpty {
                     for try await message in server.fetchMessages(using: uids) {
                        print("[\(message.uid?.value ?? 0)] \(message.subject ?? "")")
                    }
                }
            }
        }
    }
}

struct Idle: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Watch for new emails (IDLE)")
    
    @Option(name: .shortAndLong, help: "Mailbox")
    var mailbox: String = "INBOX"

    func run() throws {
        runAsyncBlock {
            // Idle is special
            try Dotenv.configure()
            
            guard case let .string(host) = Dotenv["IMAP_HOST"],
                  case let .integer(port) = Dotenv["IMAP_PORT"],
                  case let .string(username) = Dotenv["IMAP_USERNAME"],
                  case let .string(password) = Dotenv["IMAP_PASSWORD"] else {
                throw ValidationError("Missing IMAP credentials in .env")
            }
            
            let server = IMAPServer(host: host, port: port)
            try await server.connect()
            try await server.login(username: username, password: password)
            // No defer disconnect as we run indefinitely
            
            let status = try await server.selectMailbox(mailbox)
            print("Listening on \(mailbox)... (CTRL+C to stop)")
            
            let idleSession = try await server.idle(on: mailbox)
            
            var lastExists = status.messageCount
            
            for await event in idleSession.events {
                if case .exists(let count) = event, count > lastExists {
                     print("🔔 New message! (Count: \(count))")
                     lastExists = count
                }
            }
        }
    }
}

// Entry point
IMAPTool.main()
