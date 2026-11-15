#if os(macOS)
import Foundation
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPAbortTests {
    @Test(arguments: ["primary", "named", "all"])
    func abortSettlesHeldCommandAndPreservesScope(scope: String) async throws {
        let number: UInt64 = scope == "primary" ? 1 : 2
        let script = IMAPTestServer.Script(connectionNumber: number, occurrence: 5, actions: [
            .hold("reply"), .taggedCompletion("OK NOOP completed")
        ])
        try await ManagedSessionFixture.run(scripts: [script]) { fixture in
            let server = fixture.server
            let named = try await server.connection(named: "worker")
            let connection = scope == "primary" ? await server.primaryConnection : await named.connection
            let active = Task {
                if scope == "primary" { _ = try await server.noop() } else { _ = try await named.noop() }
            }
            let held = try await fixture.testServer.waitForEvent(
                .replyHeld, run: fixture.testServer.runID, detail: "reply", timeout: 10)
            let enqueued = IMAPTestSignal()
            connection.commandQueue.testHooks.didEnqueue = enqueued.signal
            let queued = Task {
                if scope == "primary" { _ = try await server.noop() } else { _ = try await named.noop() }
            }
            try await authenticationResult(Task { await enqueued.wait() })
            let commands = fixture.commands(on: number)
            await repeatedlyAbort(scope: scope, server: server, named: named)
            for caller in [active, queued] {
                await #expect(throws: IMAPConnectionAbortedError.self) {
                    try await authenticationResult(caller)
                }
            }
            _ = try await fixture.testServer.waitForConnectionEnd(
                run: held.connection.run, connection: held.connection)
            #expect(try !fixture.release(held, gate: "reply"))
            #expect(fixture.commands(on: number) == commands) // No DONE or LOGOUT.
            await #expect(throws: IMAPConnectionAbortedError.self) {
                if scope == "primary" { _ = try await server.noop() } else { _ = try await named.noop() }
            }
            if scope == "primary" {
                _ = try await named.noop()
            } else if scope == "named" {
                _ = try await server.noop()
            } else {
                _ = try await fixture.testServer.waitForConnectionEnd(
                    run: held.connection.run, connection: fixture.testServer.connection(1))
                await #expect(throws: IMAPConnectionAbortedError.self) {
                    _ = try await server.connection(named: "later")
                }
            }
            try await explicitlyReconnect(scope: scope, server: server, named: named)
        }
    }

    private func repeatedlyAbort(scope: String, server: IMAPServer, named: IMAPNamedConnection) async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    switch scope {
                        case "primary": await server.abort()
                        case "named": await named.abort()
                        default: await server.abortAllConnections()
                    }
                }
            }
        }
    }

    private func explicitlyReconnect(scope: String, server: IMAPServer, named: IMAPNamedConnection) async throws {
        if scope != "named" {
            try await server.connect()
            try await server.login(username: "u", password: "p")
            _ = try await server.selectMailbox("INBOX")
            _ = try await server.noop()
        }
        if scope != "primary" {
            // Even server.connect() must not revive an old aborted handle.
            await #expect(throws: IMAPConnectionAbortedError.self) { _ = try await named.noop() }
            try await named.connect()
            _ = try await named.selectMailbox("INBOX")
            _ = try await named.noop()
        }
        if scope == "all" { try await named.disconnect() }
    }

    @Test(arguments: [false, true])
    func cancelledDisconnectClosesHeldCommandWithoutWaitingForReply(named: Bool) async throws {
        let number: UInt64 = named ? 2 : 1
        let script = IMAPTestServer.Script(connectionNumber: number, occurrence: 5, actions: [
            .hold("reply"), .taggedCompletion("OK NOOP completed")
        ])
        try await ManagedSessionFixture.run(scripts: [script]) { fixture in
            let server = fixture.server
            let handle = named ? try await server.connection(named: "worker") : nil
            let active = Task {
                if let handle { _ = try await handle.noop() } else { _ = try await server.noop() }
            }
            let held = try await fixture.testServer.waitForEvent(
                .replyHeld, run: fixture.testServer.runID, detail: "reply", timeout: 10)
            let begin = IMAPTestSignal()
            let disconnect = Task {
                await begin.wait()
                #expect(Task.isCancelled)
                if let handle { try await handle.disconnect() } else { try await server.disconnect() }
            }
            disconnect.cancel()
            begin.signal()
            try await authenticationResult(disconnect)
            // Closing the transport fails the command while its reply is still gated.
            do {
                try await authenticationResult(active)
                Issue.record("Held command succeeded after disconnect")
            } catch {
                #expect(!(error is AuthenticationRaceError))
            }
            _ = try await fixture.testServer.waitForConnectionEnd(
                run: held.connection.run, connection: held.connection)
            #expect(try !fixture.release(held, gate: "reply"))
            #expect(fixture.commands(on: number).count == 5)
            #expect(!fixture.commands(on: number).contains { $0.contains("DONE") || $0.contains("LOGOUT") })
        }
    }

    @Test(arguments: [false, true], [false, true])
    func commandAfterDisconnectPreservesReconnectPolicy(named: Bool, reconnects: Bool) async throws {
        try await ManagedSessionFixture.run { fixture in
            let server = fixture.server
            await server.setReconnectsInsideCommands(reconnects)
            let handle = named ? try await server.connection(named: "worker") : nil
            if let handle { try await handle.disconnect() } else { try await server.disconnect() }
            let accepted = fixture.testServer.acceptedConnectionCount
            let command = Task {
                if let handle { _ = try await handle.noop() } else { _ = try await server.noop() }
            }
            if reconnects {
                try await authenticationResult(command)
                #expect(fixture.testServer.acceptedConnectionCount == accepted + 1)
                // Main deliberately clears primary authentication on disconnect;
                // named handles authenticate again before their next command.
                #expect(fixture.testServer.commandLog.last?.contains(" NOOP") == true)
                if let handle { #expect(await handle.isAuthenticated) }
            } else {
                let error = await #expect(throws: IMAPError.self) { try await authenticationResult(command) }
                guard case .connectionFailed? = error else {
                    Issue.record("Expected connectionFailed, got \(String(describing: error))")
                    return
                }
                #expect(fixture.testServer.acceptedConnectionCount == accepted)
            }
            // Server disconnect removes its named record; clean up the retained handle too.
            if let handle { try await handle.disconnect() }
        }
    }
}
#endif
