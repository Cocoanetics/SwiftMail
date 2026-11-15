#if os(macOS)
import Foundation
import Testing
@testable import SwiftMail

/// A real server and an `IMAPServer` connected and logged in on connection 1.
/// Managed connections are numbered from 2 in the order they dial. Every race is
/// ordered by fixture events or signals; callers settle and the socket reaches EOF
/// before any gate or provider is released.
struct ManagedSessionFixture {
    typealias Server = IMAPTestServer
    let testServer: Server
    let server: IMAPServer
    let completedAttempts = CompletedAttempts()

    final class CompletedAttempts: @unchecked Sendable {
        private let lock = NSLock()
        private var signals: [UUID: IMAPTestSignal] = [:]

        func signal(for id: UUID) -> IMAPTestSignal {
            lock.withLock {
                if let signal = signals[id] { return signal }
                let signal = IMAPTestSignal()
                signals[id] = signal
                return signal
            }
        }
    }

    static func run(
        scripts: [Server.Script] = [],
        _ body: (ManagedSessionFixture) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in ["cur", "new"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let testServer = try Server(username: "u", password: "p", scripts: scripts, maildirURL: root)
        try testServer.start()
        try await testServer.run {
            let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
            try await server.connect()
            try await server.login(username: "u", password: "p")
            let fixture = ManagedSessionFixture(testServer: testServer, server: server)
            await server.setNamedAttemptCompletedForTesting { [completed = fixture.completedAttempts] id in
                completed.signal(for: id).signal()
            }
            do {
                try await body(fixture)
            } catch {
                await server.invalidateManagedSession()
                throw error
            }
            await server.invalidateManagedSession()
        }
        #expect(testServer.fixtureFailures.isEmpty)
    }

    /// Holds the `tcp` bootstrap checkpoint of the first managed connection only.
    func holdFirstManagedConnection(at gate: HoldGate) async {
        let claimed = IMAPTestCounter()
        await server.setManagedConnectionCreatedForTesting { connection in
            guard claimed.increment() == 1 else { return }
            connection.lifecycleCheckpointForTesting = gate.visit
        }
    }

    func event(
        _ kind: Server.EventKind, connection number: UInt64, occurrence: Int? = nil
    ) async throws -> Server.Event {
        try await testServer.waitForEvent(
            kind, run: testServer.runID, connection: testServer.connection(number),
            occurrence: occurrence, timeout: 10)
    }

    /// The client closed the socket: FIN, or a reset when it left replies unread.
    /// The reader observes it independently of a writer blocked on a gate.
    func eof(_ number: UInt64) async throws {
        let connection = testServer.connection(number)
        _ = try await testServer.waitForEvent(
            .workerDrained, run: connection.run, connection: connection, detail: "reader", timeout: 10)
        #expect(testServer.events.contains {
            $0.connection == connection && ($0.kind == .peerEOF || $0.kind == .peerReset)
        })
    }

    func commands(on number: UInt64) -> [String] {
        testServer.commandLines(on: testServer.connection(number))
    }

    /// Releases a held reply; false when the socket already ended.
    @discardableResult
    func release(_ held: Server.Event, gate: String) throws -> Bool {
        testServer.release(try #require(held.command), gate: gate)
    }

    static let fastIdle = IMAPIdleConfiguration(
        renewalInterval: 60, noopInterval: 60, postIdleNoopEnabled: false, postIdleNoopDelay: 0,
        doneTimeout: 1, reconnectBaseDelay: 0.01, reconnectMaxDelay: 0.01, reconnectJitterFactor: 0)

    /// Occurrences on a fresh managed connection: greeting 0, CAPABILITY 1, LOGIN 2,
    /// CAPABILITY 3, NAMESPACE 4, SELECT 5, IDLE 6.
    static func heldReply(_ stage: String, connection: UInt64) -> [Server.Script] {
        let script: (Int, String) -> [Server.Script] = { occurrence, completion in
            [Server.Script(connectionNumber: connection, occurrence: occurrence,
                           actions: [.hold(stage), .taggedCompletion(completion)])]
        }
        switch stage {
            case "greeting":
                return [Server.Script(connectionNumber: connection, occurrence: 0, actions: [
                    .hold(stage), .send(Data("* OK ready\r\n".utf8), acknowledgement: "greeting")
                ])]
            case "auth": return script(2, "OK LOGIN completed")
            case "select": return script(5, "OK [READ-WRITE] SELECT completed")
            default: return []
        }
    }

    static func heldOccurrence(_ stage: String) -> Int {
        ["greeting": 0, "auth": 2, "select": 5][stage] ?? 0
    }
}

func streamFinishes(_ session: IMAPIdleSession) async throws {
    try await authenticationResult(Task { for await _ in session.events {} })
}
#endif
