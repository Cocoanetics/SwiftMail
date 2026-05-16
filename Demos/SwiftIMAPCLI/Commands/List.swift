import ArgumentParser
import Foundation
import SwiftMail

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
                    let header = "[\(message.uid?.value ?? 0)] \(message.date?.description ?? "")"
                    print("\(header) - \(message.from ?? "Unknown")")
                    print("   \(message.subject ?? "(No Subject)")")
                }
            }
        }
    }
}
