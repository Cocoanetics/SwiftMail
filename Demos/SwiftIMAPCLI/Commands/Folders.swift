import ArgumentParser
import Foundation
import SwiftMail

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
