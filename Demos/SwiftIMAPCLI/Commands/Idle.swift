import Foundation
import ArgumentParser
import SwiftMail

struct Idle: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Watch for IMAP IDLE events (all types)")

    @Option(name: .shortAndLong, help: "Mailbox")
    var mailbox: String = "INBOX"

    @Option(name: .shortAndLong, help: "IDLE heartbeat interval in seconds (DONE → NOOP → re-IDLE)")
    var cycle: Int = 300

    func run() throws {
        runAsyncBlock {
            let environment = try loadIMAPEnvironment()

            let server = IMAPServer(host: environment.host, port: environment.port)
            print("Connecting to \(environment.host):\(environment.port)...")
            try await server.connect()
            print("Connected.")
            try await authenticate(server: server, using: environment)

            let status = try await server.selectMailbox(mailbox)
            print("📬 \(mailbox): \(status.messageCount) messages")
            print("Listening for IDLE events (heartbeat: \(cycle)s, Ctrl+C to stop)...\n")

            var idleConfiguration = IMAPIdleConfiguration.default
            idleConfiguration.noopInterval = TimeInterval(cycle)
            let idleSession = try await server.idle(on: mailbox, configuration: idleConfiguration)

            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"

            for await event in idleSession.events {
                let timestamp = formatter.string(from: Date())
                Self.printEvent(event, timestamp: timestamp)
            }

            print("\nIDLE stream ended.")
            try? await idleSession.done()
            try? await server.disconnect()
        }
    }

    private static func printEvent(_ event: IMAPServerEvent, timestamp: String) {
        switch event {
        case .exists(let count):
            print("[\(timestamp)] 📩 EXISTS count=\(count)")
        case .expunge(let seq):
            print("[\(timestamp)] 🗑️  EXPUNGE seq=\(seq.value)")
        case .recent(let count):
            print("[\(timestamp)] 🆕 RECENT count=\(count)")
        case .vanished(let uids):
            print("[\(timestamp)] 💨 VANISHED \(uids.count) UID(s)")
        case .flags(let flags):
            let flagList = flags.map(\.description).joined(separator: ", ")
            print("[\(timestamp)] 🏷️  FLAGS [\(flagList)]")
        default:
            printSecondaryEvent(event, timestamp: timestamp)
        }
    }

    private static func printSecondaryEvent(_ event: IMAPServerEvent, timestamp: String) {
        switch event {
        case .fetch(let seq, let attrs):
            let flags = attrs.compactMap { attr -> String? in
                if case .flags(let flagList) = attr { return flagList.map(String.init).joined(separator: ", ") }
                return nil
            }.first ?? ""
            print("[\(timestamp)] 📋 FETCH seq=\(seq.value) flags=[\(flags)]")
        case .fetchUID(let uid, let attrs):
            let flags = attrs.compactMap { attr -> String? in
                if case .flags(let flagList) = attr { return flagList.map(String.init).joined(separator: ", ") }
                return nil
            }.first ?? ""
            print("[\(timestamp)] 📋 FETCH uid=\(uid.value) flags=[\(flags)]")
        case .bye(let text):
            print("[\(timestamp)] 👋 BYE: \(text ?? "")")
        case .alert(let text):
            print("[\(timestamp)] ⚠️  ALERT: \(text)")
        case .capability(let caps):
            print("[\(timestamp)] 🔧 CAPABILITY: \(caps.joined(separator: " "))")
        default:
            break
        }
    }
}
