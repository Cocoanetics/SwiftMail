import Foundation
import ArgumentParser
import SwiftMail

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
