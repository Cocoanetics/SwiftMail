import ArgumentParser
import Foundation
import Logging
import SwiftMail

/// Setup Logger (silence unless debug)
let logger = Logger(label: "com.cocoanetics.SwiftIMAPCLI")

/// Helper to run async code synchronously
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

/// Helper to manage server lifecycle
func withServer<T>(_ block: (IMAPServer) async throws -> T) async throws -> T {
    let environment = try loadIMAPEnvironment()

    let server = IMAPServer(host: environment.host, port: environment.port)
    print("Connecting to \(environment.host):\(environment.port)...")
    try await server.connect()
    print("Connected.")
    try await authenticate(server: server, using: environment)

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

struct IMAPTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "SwiftIMAPCLI",
        abstract: "A CLI for interacting with IMAP servers using SwiftMail.",
        subcommands: [List.self, Fetch.self, Move.self, Idle.self, Search.self, Folders.self, DownloadAttachment.self]
    )
}

// Entry point
IMAPTool.main()
