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
        subcommands: [List.self, Fetch.self, Move.self, Idle.self, Search.self, Folders.self, DownloadAttachment.self]
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
    print("Connecting to \(host):\(port)...")
    try await server.connect()
    print("Connected. Logging in as \(username)...")
    try await server.login(username: username, password: password)
    print("Login OK.")
    
    do {
        let result = try await block(server)
        print("Disconnecting...")
        try await server.disconnect()
        print("Disconnected.")
        return result
    } catch {
        print("Error in command, disconnecting...")
        try? await server.disconnect()
        throw error
    }
}

struct Folders: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List all mailboxes")

    func run() throws {
        runAsyncBlock {
            try await withServer { server in
                let special = try await server.listSpecialUseMailboxes()
                print("📂 Special Folders:")
                if let inbox = special.inbox { print("  - INBOX: \(inbox.name)") }
                if let drafts = special.drafts { print("  - Drafts: \(drafts.name)") }
                if let sent = special.sent { print("  - Sent: \(sent.name)") }
                if let trash = special.trash { print("  - Trash: \(trash.name)") }
                if let junk = special.junk { print("  - Junk: \(junk.name)") }
                if let archive = special.archive { print("  - Archive: \(archive.name)") }
            }
        }
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
    
    @Argument(help: "UID(s) of the message (comma-separated; ranges like 1-3 allowed)")
    var uid: String

    @Option(name: .shortAndLong, help: "Mailbox")
    var mailbox: String = "INBOX"
    
    @ArgumentParser.Flag(help: "Download raw RFC 822 message as .eml file")
    var eml: Bool = false
    
    @Option(help: "Output directory (saves .eml with --eml, or .txt/.html without)")
    var out: String?

    func run() throws {
        runAsyncBlock {
            try await withServer { server in
                print("Selecting mailbox \(mailbox)...")
                _ = try await server.selectMailbox(mailbox)
                print("Mailbox selected.")
                
                guard let uids = MessageIdentifierSet<UID>(string: uid) else {
                    throw ValidationError("Invalid UID list: \(uid)")
                }
                
                var outputURL: URL?
                if let out {
                    outputURL = URL(fileURLWithPath: out, isDirectory: true)
                    try FileManager.default.createDirectory(at: outputURL!, withIntermediateDirectories: true, attributes: nil)
                }
                
                var found = false
                
                for try await message in server.fetchMessages(using: uids) {
                    found = true
                    guard let msgUID = message.uid else { continue }
                    
                    // Sanitized subject for filenames
                    let safeSubject = message.subject.map {
                        String($0
                            .replacingOccurrences(of: "/", with: "-")
                            .replacingOccurrences(of: ":", with: "-")
                            .replacingOccurrences(of: "\\", with: "-")
                            .prefix(80))
                    }
                    
                    if eml {
                        let data = try await server.fetchRawMessage(identifier: msgUID)
                        let filename = safeSubject.map { "\(msgUID.value)-\($0).eml" } ?? "message-\(msgUID.value).eml"
                        let destination = (outputURL ?? URL(fileURLWithPath: ".")).appendingPathComponent(filename)
                        try data.write(to: destination)
                        print("Saved \(destination.path) (\(data.count) bytes)")
                    } else if let outputURL {
                        // Write parsed content to file
                        var content = ""
                        content += "From: \(message.from ?? "")\n"
                        content += "To: \(message.to.joined(separator: ", "))\n"
                        content += "Subject: \(message.subject ?? "")\n"
                        content += "Date: \(message.date?.description ?? "")\n\n"
                        
                        let ext: String
                        if let text = message.textBody {
                            content += text
                            ext = "txt"
                        } else if let html = message.htmlBody {
                            content += html
                            ext = "html"
                        } else {
                            content += "(No body)"
                            ext = "txt"
                        }
                        
                        let filename = safeSubject.map { "\(msgUID.value)-\($0).\(ext)" } ?? "message-\(msgUID.value).\(ext)"
                        let destination = outputURL.appendingPathComponent(filename)
                        try content.write(to: destination, atomically: true, encoding: .utf8)
                        print("Saved \(destination.path)")
                    } else {
                        // Print to stdout
                        print("--- Message \(uid) ---")
                        print("From: \(message.from ?? "")")
                        print("Subject: \(message.subject ?? "")")
                        print("Date: \(message.date?.description ?? "")")
                        print("\nBody:")
                        if let text = message.textBody {
                            print(text)
                        } else if let html = message.htmlBody {
                            print("(HTML Body)\n")
                            print(html)
                        }
                        
                        if !message.attachments.isEmpty {
                            print("\nAttachments: \(message.attachments.count)")
                            for part in message.attachments {
                                print("- \(part.filename ?? "unnamed") (\(part.contentType))")
                            }
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
    
    @Argument(help: "UID(s) of the message (comma-separated; ranges like 1-3 allowed)")
    var uid: String
    
    @Argument(help: "Target mailbox")
    var target: String

    @Option(name: .shortAndLong, help: "Source Mailbox")
    var mailbox: String = "INBOX"

    func run() throws {
        runAsyncBlock {
            try await withServer { server in
                _ = try await server.selectMailbox(mailbox)
                
                guard let uids = MessageIdentifierSet<UID>(string: uid) else {
                    throw ValidationError("Invalid UID list: \(uid)")
                }
                try await server.move(messages: uids, to: target)
                print("Moved UID \(uid) to \(target)")
            }
        }
    }
}

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search emails",
        discussion: """
        Examples:
          SwiftIMAPCLI search --from "Card Complete" --subject Mastercard
          SwiftIMAPCLI search --from "Card Complete" --subject Mastercard --attachment pdf
          SwiftIMAPCLI search --text invoice --since 2025-01-01 --any
        """
    )
    
    @Option(name: .shortAndLong, help: "Mailbox")
    var mailbox: String = "INBOX"
    
    @Option(help: "Match From field (repeatable)")
    var from: [String] = []
    
    @Option(help: "Match Subject field (repeatable)")
    var subject: [String] = []
    
    @Option(help: "Match text in headers and body (repeatable)")
    var text: [String] = []
    
    @Option(help: "Match body only (repeatable)")
    var body: [String] = []
    
    @Option(help: "Match To field (repeatable)")
    var to: [String] = []
    
    @Option(help: "Match Cc field (repeatable)")
    var cc: [String] = []
    
    @Option(help: "Match Bcc field (repeatable)")
    var bcc: [String] = []
    
    @Option(help: "Match header FIELD:VALUE (repeatable)")
    var header: [String] = []
    
    @Option(help: "Internal date since (YYYY-MM-DD)")
    var since: String?
    
    @Option(help: "Internal date before (YYYY-MM-DD)")
    var before: String?
    
    @Option(help: "Internal date on (YYYY-MM-DD)")
    var on: String?
    
    @Option(help: "Sent date since (YYYY-MM-DD)")
    var sentSince: String?
    
    @Option(help: "Sent date before (YYYY-MM-DD)")
    var sentBefore: String?
    
    @Option(help: "Sent date on (YYYY-MM-DD)")
    var sentOn: String?
    
    @Option(help: "Messages larger than size in bytes")
    var larger: Int?
    
    @Option(help: "Messages smaller than size in bytes")
    var smaller: Int?
    
    @ArgumentParser.Flag(help: "Seen messages")
    var seen: Bool = false
    
    @ArgumentParser.Flag(help: "Unseen messages")
    var unseen: Bool = false
    
    @ArgumentParser.Flag(help: "Flagged messages")
    var flagged: Bool = false
    
    @ArgumentParser.Flag(help: "Unflagged messages")
    var unflagged: Bool = false
    
    @ArgumentParser.Flag(help: "Answered messages")
    var answered: Bool = false
    
    @ArgumentParser.Flag(help: "Unanswered messages")
    var unanswered: Bool = false
    
    @ArgumentParser.Flag(help: "Deleted messages")
    var deleted: Bool = false
    
    @ArgumentParser.Flag(help: "Undeleted messages")
    var undeleted: Bool = false
    
    @ArgumentParser.Flag(help: "Draft messages")
    var draft: Bool = false
    
    @ArgumentParser.Flag(help: "Undraft messages")
    var undraft: Bool = false
    
    @ArgumentParser.Flag(help: "Recent messages")
    var recent: Bool = false
    
    @ArgumentParser.Flag(help: "New messages (Recent but not Seen)")
    var new: Bool = false
    
    @ArgumentParser.Flag(help: "Old messages (not Recent)")
    var old: Bool = false
    
    @ArgumentParser.Flag(help: "Use OR instead of AND across all criteria")
    var any: Bool = false
    
    @Option(help: "Attachment file extension to match (repeatable, e.g. pdf, docx)")
    var attachment: [String] = []
    
    private func parseDate(_ value: String, label: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: value) else {
            throw ValidationError("Invalid \(label) date: \(value). Expected YYYY-MM-DD.")
        }
        return date
    }
    
    private func buildCriteria() throws -> [SearchCriteria] {
        var criterias: [SearchCriteria] = []
        
        func groupOr(_ items: [SearchCriteria]) -> SearchCriteria? {
            guard let first = items.first else { return nil }
            return items.dropFirst().reduce(first) { .or($0, $1) }
        }
        
        if let grouped = groupOr(from.map { .from($0) }) { criterias.append(grouped) }
        if let grouped = groupOr(subject.map { .subject($0) }) { criterias.append(grouped) }
        if let grouped = groupOr(text.map { .text($0) }) { criterias.append(grouped) }
        if let grouped = groupOr(body.map { .body($0) }) { criterias.append(grouped) }
        if let grouped = groupOr(to.map { .to($0) }) { criterias.append(grouped) }
        if let grouped = groupOr(cc.map { .cc($0) }) { criterias.append(grouped) }
        if let grouped = groupOr(bcc.map { .bcc($0) }) { criterias.append(grouped) }
        
        var headerCriteria: [SearchCriteria] = []
        for headerValue in header {
            let parts = headerValue.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw ValidationError("Invalid header format: \(headerValue). Expected FIELD:VALUE.")
            }
            headerCriteria.append(.header(parts[0], parts[1]))
        }
        if let grouped = groupOr(headerCriteria) { criterias.append(grouped) }
        
        if let since {
            criterias.append(.since(try parseDate(since, label: "--since")))
        }
        if let before {
            criterias.append(.before(try parseDate(before, label: "--before")))
        }
        if let on {
            criterias.append(.on(try parseDate(on, label: "--on")))
        }
        if let sentSince {
            criterias.append(.sentSince(try parseDate(sentSince, label: "--sent-since")))
        }
        if let sentBefore {
            criterias.append(.sentBefore(try parseDate(sentBefore, label: "--sent-before")))
        }
        if let sentOn {
            criterias.append(.sentOn(try parseDate(sentOn, label: "--sent-on")))
        }
        
        if let larger {
            criterias.append(.larger(larger))
        }
        if let smaller {
            criterias.append(.smaller(smaller))
        }
        
        if seen { criterias.append(.seen) }
        if unseen { criterias.append(.unseen) }
        if flagged { criterias.append(.flagged) }
        if unflagged { criterias.append(.unflagged) }
        if answered { criterias.append(.answered) }
        if unanswered { criterias.append(.unanswered) }
        if deleted { criterias.append(.deleted) }
        if undeleted { criterias.append(.undeleted) }
        if draft { criterias.append(.draft) }
        if undraft { criterias.append(.undraft) }
        if recent { criterias.append(.recent) }
        if new { criterias.append(.new) }
        if old { criterias.append(.old) }
        
        if criterias.isEmpty {
            throw ValidationError("No search criteria provided. Use --subject, --from, --text, etc.")
        }
        
        if any && criterias.count > 1 {
            return [criterias.reduce(criterias[0]) { .or($0, $1) }]
        }
        
        return criterias
    }
    
    private func attachmentExtensions() -> Set<String> {
        Set(
            attachment
                .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
        )
    }

    func run() throws {
        runAsyncBlock {
            try await withServer { server in
                _ = try await server.selectMailbox(mailbox)
                
                print("Building search criteria...")
                let criteria = try buildCriteria()
                print("Running IMAP SEARCH...")
                let uids: MessageIdentifierSet<UID> = try await server.search(criteria: criteria)
                let attachmentExts = attachmentExtensions()
                let criteriaDescription = any ? "OR" : "AND"
                print("Found \(uids.count) messages matching \(criteriaDescription) criteria")
                
                if !uids.isEmpty {
                     print("Fetching messages for results...")
                     for try await message in server.fetchMessages(using: uids) {
                        if !attachmentExts.isEmpty {
                            let hasMatch = message.attachments.contains { part in
                                guard let filename = part.filename?.lowercased() else { return false }
                                return attachmentExts.contains(where: { filename.hasSuffix(".\($0)") })
                            }
                            if !hasMatch {
                                continue
                            }
                        }
                        
                        let uidValue = message.uid?.value ?? 0
                        print("--- UID \(uidValue) ---")
                        print("From: \(message.from ?? "")")
                        let toList = message.to.joined(separator: ", ")
                        print("To: \(toList)")
                        print("Subject: \(message.subject ?? "")")
                        print("Date: \(message.date?.description ?? "")")
                        
                        if message.attachments.isEmpty {
                            print("Attachments: 0")
                        } else {
                            print("Attachments: \(message.attachments.count)")
                            for part in message.attachments {
                                print("- \(part.filename ?? "unnamed") (\(part.contentType))")
                            }
                        }
                    }
                }
            }
        }
    }
}

struct DownloadAttachment: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attachment",
        abstract: "Download attachments for a message UID"
    )
    
    @Argument(help: "UID(s) of the message (comma-separated; ranges like 1-3 allowed)")
    var uid: String
    
    @Option(name: .shortAndLong, help: "Mailbox")
    var mailbox: String = "INBOX"
    
    @Option(help: "Attachment file extension to match (repeatable, e.g. pdf, docx)")
    var attachment: [String] = []
    
    @Option(help: "Output directory")
    var out: String = "."
    
    private func attachmentExtensions() -> Set<String> {
        Set(
            attachment
                .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
        )
    }
    
    func run() throws {
        runAsyncBlock {
            try await withServer { server in
                print("Selecting mailbox \(mailbox)...")
                _ = try await server.selectMailbox(mailbox)
                print("Mailbox selected.")
                
                guard let uids = MessageIdentifierSet<UID>(string: uid) else {
                    throw ValidationError("Invalid UID list: \(uid)")
                }
                let outputURL = URL(fileURLWithPath: out, isDirectory: true)
                try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true, attributes: nil)
                print("Output directory: \(outputURL.path)")
                
                var found = false
                let attachmentExts = attachmentExtensions()
                print("Fetching message UID(s) \(uid)...")
                
                for try await message in server.fetchMessages(using: uids) {
                    found = true
                    var parts = message.attachments
                    if !attachmentExts.isEmpty {
                        parts = parts.filter { part in
                            guard let filename = part.filename?.lowercased() else { return false }
                            return attachmentExts.contains(where: { filename.hasSuffix(".\($0)") })
                        }
                    }
                    
                    if parts.isEmpty {
                        print("No matching attachments found for UID \(message.uid?.value ?? 0).")
                        return
                    }
                    
                    for part in parts {
                        let filename = part.suggestedFilename
                        let destination = outputURL.appendingPathComponent(filename)
                        print("Saving \(filename)...")
                        guard let data = part.decodedData() ?? part.data else {
                            throw ValidationError("Attachment data missing for \(filename)")
                        }
                        try data.write(to: destination)
                        print("Saved \(filename) to \(destination.path)")
                    }
                }
                
                if !found {
                    print("Message UID(s) \(uid) not found.")
                }
            }
        }
    }
    
}

struct Idle: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Watch for IMAP IDLE events (all types)")
    
    @Option(name: .shortAndLong, help: "Mailbox")
    var mailbox: String = "INBOX"
    
    @Option(name: .shortAndLong, help: "IDLE cycle interval in seconds (DONE → NOOP → re-IDLE)")
    var cycle: Int = 240

    func run() throws {
        runAsyncBlock {
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
            
            let status = try await server.selectMailbox(mailbox)
            print("📬 \(mailbox): \(status.messageCount) messages")
            print("Listening for IDLE events (cycle: \(cycle)s, Ctrl+C to stop)...\n")
            
            let idleSession = try await server.idle(on: mailbox, cycleInterval: TimeInterval(cycle))
            
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            
            for await event in idleSession.events {
                let ts = formatter.string(from: Date())
                switch event {
                case .exists(let count):
                    print("[\(ts)] 📩 EXISTS count=\(count)")
                case .expunge(let seq):
                    print("[\(ts)] 🗑️  EXPUNGE seq=\(seq.value)")
                case .recent(let count):
                    print("[\(ts)] 🆕 RECENT count=\(count)")
                case .fetch(let seq, let attrs):
                    let flags = attrs.compactMap { attr -> String? in
                        if case .flags(let f) = attr { return f.map(String.init).joined(separator: ", ") }
                        return nil
                    }.first ?? ""
                    print("[\(ts)] 📋 FETCH seq=\(seq.value) flags=[\(flags)]")
                case .fetchUID(let uid, let attrs):
                    let flags = attrs.compactMap { attr -> String? in
                        if case .flags(let f) = attr { return f.map(String.init).joined(separator: ", ") }
                        return nil
                    }.first ?? ""
                    print("[\(ts)] 📋 FETCH uid=\(uid.value) flags=[\(flags)]")
                case .vanished(let uids):
                    let count = uids.count
                    print("[\(ts)] 💨 VANISHED \(count) UID(s)")
                case .flags(let flags):
                    let flagList = flags.map(\.description).joined(separator: ", ")
                    print("[\(ts)] 🏷️  FLAGS [\(flagList)]")
                case .bye(let text):
                    print("[\(ts)] 👋 BYE: \(text ?? "")")
                case .alert(let text):
                    print("[\(ts)] ⚠️  ALERT: \(text)")
                case .capability(let caps):
                    print("[\(ts)] 🔧 CAPABILITY: \(caps.joined(separator: " "))")
                }
            }
            
            print("\nIDLE stream ended.")
            try? await idleSession.done()
            try? await server.disconnect()
        }
    }
}

// Entry point
IMAPTool.main()
