import Foundation
import ArgumentParser
import SwiftMail

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

    @Option(help: "Sort key (repeatable). Prefix with '-' for descending, e.g. --sort -date --sort subject")
    var sort: [String] = []

    @Option(help: "Attachment file extension to match (repeatable, e.g. pdf, docx)")
    var attachment: [String] = []

    func run() throws {
        runAsyncBlock {
            try await withServer { server in
                _ = try await server.selectMailbox(mailbox)

                print("Building search criteria...")
                let criteria = try buildCriteria()
                let sortCriteria = try buildSortCriteria()
                let sortDescription = sortCriteria.isEmpty ? "none" : sort.map { $0 }.joined(separator: ", ")
                print("Running IMAP SEARCH (sort: \(sortDescription))...")
                let searchResult: ExtendedSearchResult<UID> = try await server.extendedSearch(
                    criteria: criteria,
                    sortCriteria: sortCriteria
                )
                let uids = searchResult.all ?? MessageIdentifierSet<UID>()
                let attachmentExts = attachmentExtensions()
                let criteriaDescription = any ? "OR" : "AND"
                print("Found \(uids.count) messages matching \(criteriaDescription) criteria")
                try await reportResults(
                    searchResult: searchResult,
                    uids: uids,
                    attachmentExts: attachmentExts,
                    server: server
                )
            }
        }
    }

    private func reportResults(
        searchResult: ExtendedSearchResult<UID>,
        uids: MessageIdentifierSet<UID>,
        attachmentExts: Set<String>,
        server: IMAPServer
    ) async throws {
        guard !uids.isEmpty else { return }
        let orderedUIDs = searchResult.ordered ?? uids.toArray()
        print("Fetching messages for results...")
        for uid in orderedUIDs {
            guard let header = try await server.fetchMessageInfo(for: uid) else {
                continue
            }
            let message = try await server.fetchMessage(from: header)
            if message.uid == nil {
                continue
            }
            if !attachmentExts.isEmpty && !Self.hasMatchingAttachment(in: message, extensions: attachmentExts) {
                continue
            }
            Self.printResult(message: message, fallbackUID: uid)
        }
    }

    private static func hasMatchingAttachment(in message: Message, extensions: Set<String>) -> Bool {
        message.attachments.contains { part in
            guard let filename = part.filename?.lowercased() else { return false }
            return extensions.contains(where: { filename.hasSuffix(".\($0)") })
        }
    }

    private static func printResult(message: Message, fallbackUID: UID) {
        let uidValue = message.uid?.value ?? fallbackUID.value
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
