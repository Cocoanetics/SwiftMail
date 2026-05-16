import Foundation
import ArgumentParser
import SwiftMail

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

                let outputURL = try Self.prepareOutputURL(out: out)
                var found = false
                for try await message in server.fetchMessages(using: uids) {
                    found = true
                    try await handle(message: message, server: server, outputURL: outputURL)
                }

                if !found {
                    print("Message UID \(uid) not found.")
                }
            }
        }
    }

    private func handle(
        message: Message,
        server: IMAPServer,
        outputURL: URL?
    ) async throws {
        guard let msgUID = message.uid else { return }
        let safeSubject = Self.safeSubject(for: message)

        if eml {
            try await Self.saveRawEml(
                server: server,
                msgUID: msgUID,
                safeSubject: safeSubject,
                outputURL: outputURL
            )
        } else if let outputURL {
            try Self.saveParsedContent(
                message: message,
                msgUID: msgUID,
                safeSubject: safeSubject,
                outputURL: outputURL
            )
        } else {
            Self.printMessage(message: message, uid: uid)
        }
    }

    private static func prepareOutputURL(out: String?) throws -> URL? {
        guard let out else { return nil }
        let outputURL = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return outputURL
    }

    private static func safeSubject(for message: Message) -> String? {
        message.subject.map {
            String($0
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: "\\", with: "-")
                .prefix(80))
        }
    }

    private static func saveRawEml(
        server: IMAPServer,
        msgUID: UID,
        safeSubject: String?,
        outputURL: URL?
    ) async throws {
        let data = try await server.fetchRawMessage(identifier: msgUID)
        let filename = safeSubject.map { "\(msgUID.value)-\($0).eml" } ?? "message-\(msgUID.value).eml"
        let destination = (outputURL ?? URL(fileURLWithPath: ".")).appendingPathComponent(filename)
        try data.write(to: destination)
        print("Saved \(destination.path) (\(data.count) bytes)")
    }

    private static func saveParsedContent(
        message: Message,
        msgUID: UID,
        safeSubject: String?,
        outputURL: URL
    ) throws {
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

        let filename = safeSubject.map { "\(msgUID.value)-\($0).\(ext)" }
            ?? "message-\(msgUID.value).\(ext)"
        let destination = outputURL.appendingPathComponent(filename)
        try content.write(to: destination, atomically: true, encoding: .utf8)
        print("Saved \(destination.path)")
    }

    private static func printMessage(message: Message, uid: String) {
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
