import Foundation
import ArgumentParser
import SwiftMail

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
                try FileManager.default.createDirectory(
                    at: outputURL,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                print("Output directory: \(outputURL.path)")

                let attachmentExts = attachmentExtensions()
                print("Fetching message UID(s) \(uid)...")
                let found = try await downloadAll(
                    server: server,
                    uids: uids,
                    attachmentExts: attachmentExts,
                    outputURL: outputURL
                )

                if !found {
                    print("Message UID(s) \(uid) not found.")
                }
            }
        }
    }

    private func downloadAll(
        server: IMAPServer,
        uids: MessageIdentifierSet<UID>,
        attachmentExts: Set<String>,
        outputURL: URL
    ) async throws -> Bool {
        var found = false
        for try await message in server.fetchMessages(using: uids) {
            found = true
            let parts = Self.filterAttachments(in: message, extensions: attachmentExts)
            if parts.isEmpty {
                print("No matching attachments found for UID \(message.uid?.value ?? 0).")
                return found
            }
            try Self.saveAttachments(parts, to: outputURL)
        }
        return found
    }

    private static func filterAttachments(in message: Message, extensions: Set<String>) -> [MessagePart] {
        guard !extensions.isEmpty else { return message.attachments }
        return message.attachments.filter { part in
            guard let filename = part.filename?.lowercased() else { return false }
            return extensions.contains(where: { filename.hasSuffix(".\($0)") })
        }
    }

    private static func saveAttachments(_ parts: [MessagePart], to outputURL: URL) throws {
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
}
