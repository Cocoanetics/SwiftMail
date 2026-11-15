#if os(macOS)
import Foundation
import Testing
@testable import SwiftMail

// MARK: - Managed named creation

extension IMAPNamedConnectionTests {
    @Test(arguments: [false, true])
    func cancellingOneSameNameCreationWaiterLeavesTheOthers(cancelInitiator: Bool) async throws {
        let scripts = ManagedSessionFixture.heldReply("auth", connection: 2)
        try await ManagedSessionFixture.run(scripts: scripts) { fixture in
            let server = fixture.server
            let initiator = Task { try await server.connection(named: "shared") }
            let held = try await fixture.event(.replyHeld, connection: 2, occurrence: 2)
            let follower = Task { try await server.connection(named: " shared ") }
            let survivor = Task { try await server.connection(named: "shared") }
            try await authenticationWaitUntil {
                await server.pendingNamedConnectionForTesting["shared"]?.attempt.waiterCount == 3
            }
            let attempt = try #require(await server.pendingNamedConnectionForTesting["shared"]?.attempt)
            let cancelled = cancelInitiator ? initiator : follower
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await authenticationResult(cancelled) }
            #expect(attempt.waiterCount == 2)
            #expect(!attempt.terminal.isSettled)

            #expect(try fixture.release(held, gate: "auth"))
            let first = try await authenticationResult(cancelInitiator ? follower : initiator)
            let second = try await authenticationResult(survivor)
            #expect(first === second)
            #expect(try await server.connection(named: "shared") === first)
            #expect(await server.pendingNamedConnectionForTesting.isEmpty)
            #expect(fixture.testServer.acceptedConnectionCount == 2)
        }
    }

    /// Terminal invalidation and `disconnect()` both settle every creation waiter
    /// and close the captured socket before the held step continues.
    @Test(arguments: ["tcp", "greeting", "auth", "oauth"], [false, true])
    func invalidationSettlesHeldNamedCreation(stage: String, viaDisconnect: Bool) async throws {
        let gate = HoldGate("tcp")
        let provider = HeldAuthenticationProvider()
        defer { gate.release.signal(); provider.release.signal() }
        let scripts = ManagedSessionFixture.heldReply(stage, connection: 2)
        try await ManagedSessionFixture.run(scripts: scripts) { fixture in
            let server = fixture.server
            switch stage {
                case "tcp": await fixture.holdFirstManagedConnection(at: gate)
                case "oauth":
                    await server.setXOAUTH2AccessTokenProvider(email: "u", accessTokenProvider: provider.token)
                default: break
            }
            let first = Task { try await server.connection(named: "shared") }
            let second = Task { try await server.connection(named: "shared") }
            var held: IMAPTestServer.Event?
            switch stage {
                case "tcp": await gate.entered.wait()
                case "oauth": await provider.entered.wait()
                default:
                    held = try await fixture.event(
                        .replyHeld, connection: 2, occurrence: ManagedSessionFixture.heldOccurrence(stage))
            }
            try await authenticationWaitUntil {
                await server.pendingNamedConnectionForTesting["shared"]?.attempt.waiterCount == 2
            }
            let attempt = try #require(await server.pendingNamedConnectionForTesting["shared"]?.attempt)

            if viaDisconnect {
                try await authenticationResult(Task { try await server.disconnect() })
            } else {
                await server.invalidateManagedSession()
            }
            await #expect(throws: IMAPConnectionAbortedError()) { try await authenticationResult(first) }
            await #expect(throws: IMAPConnectionAbortedError()) { try await authenticationResult(second) }
            try await fixture.eof(2)

            // Only now let the stalled step continue; it can no longer publish.
            if let held { #expect(try !fixture.release(held, gate: stage)) }
            gate.release.signal()
            provider.release.signal()
            await fixture.completedAttempts.signal(for: attempt.id).wait()
            #expect(await server.pendingNamedConnectionForTesting.isEmpty)
            #expect(await server.namedConnections.isEmpty)
            if !viaDisconnect {
                await #expect(throws: IMAPConnectionAbortedError()) {
                    try await server.connection(named: "shared")
                }
            }
            #expect(!fixture.commands(on: 2).contains { $0.contains("LOGIN") || $0.contains("AUTHENTICATE") }
                    || stage == "auth")
            #expect(fixture.testServer.acceptedConnectionCount == 2)
        }
    }

    /// Connections: 1 primary, 2 old attempt, 3 primary after rearm, 4 new attempt.
    @Test
    func staleCompletionAfterRearmCannotEraseTheNewSameNameAttempt() async throws {
        let gate = HoldGate("tcp")
        defer { gate.release.signal() }
        let scripts = ManagedSessionFixture.heldReply("auth", connection: 4)
        try await ManagedSessionFixture.run(scripts: scripts) { fixture in
            let server = fixture.server
            await fixture.holdFirstManagedConnection(at: gate)
            let old = Task { try await server.connection(named: "x") }
            await gate.entered.wait()
            let oldAttempt = try #require(await server.pendingNamedConnectionForTesting["x"]?.attempt)
            await server.invalidateManagedSession()
            await #expect(throws: IMAPConnectionAbortedError()) { try await authenticationResult(old) }
            try await fixture.eof(2)

            try await server.connect()
            let fresh = Task { try await server.connection(named: "x") }
            let held = try await fixture.event(.replyHeld, connection: 4, occurrence: 2)
            let freshAttempt = try #require(await server.pendingNamedConnectionForTesting["x"]?.attempt)
            #expect(freshAttempt.id != oldAttempt.id)

            gate.release.signal()
            await gate.exited.wait()
            await fixture.completedAttempts.signal(for: oldAttempt.id).wait()
            #expect(await server.pendingNamedConnectionForTesting["x"]?.attempt.id == freshAttempt.id)
            #expect(!freshAttempt.terminal.isSettled)

            #expect(try fixture.release(held, gate: "auth"))
            let handle = try await authenticationResult(fresh)
            #expect(await server.namedConnections["x"]?.handle === handle)
            #expect(await handle.isAuthenticated)
            #expect(fixture.commands(on: 2).isEmpty)
        }
    }

    /// `disconnect()` suspends while closing published named connections. Creation
    /// requested in that window is refused instead of escaping the teardown, and
    /// admission reopens once the disconnect has finished.
    @Test
    func creationDuringSuspendedDisconnectIsRefused() async throws {
        try await ManagedSessionFixture.run { fixture in
            let server = fixture.server
            _ = try await server.connection(named: "published")
            let connection = try #require(await server.namedConnections["published"]?.connection)
            let closing = HoldGate("close")
            connection.beforeTransportCloseForTesting = { _ in await closing.visit("close") }
            defer { closing.release.signal() }

            let disconnect = Task { try await server.disconnect() }
            await closing.entered.wait()
            await #expect(throws: IMAPConnectionAbortedError()) {
                try await authenticationResult(Task { try await server.connection(named: "late") })
            }
            await #expect(throws: IMAPConnectionAbortedError()) {
                try await authenticationResult(Task {
                    try await server.idle(on: "INBOX", configuration: ManagedSessionFixture.fastIdle)
                })
            }
            closing.release.signal()
            try await authenticationResult(disconnect)
            #expect(await server.pendingNamedConnectionForTesting.isEmpty)
            #expect(await server.namedConnections.isEmpty)
            #expect(await server.idleConnections.isEmpty)
            #expect(fixture.testServer.acceptedConnectionCount == 2)

            _ = try await server.connection(named: "late")
            #expect(fixture.testServer.acceptedConnectionCount == 3)
        }
    }

    /// Old named handles stay aborted after the server rearms; their own
    /// `connect()` rearms them, and a new same-name request gets a new handle.
    @Test
    func rearmDoesNotReviveOldNamedHandles() async throws {
        try await ManagedSessionFixture.run { fixture in
            let server = fixture.server
            let old = try await server.connection(named: "x")
            await server.invalidateManagedSession()
            try await fixture.eof(2)
            await #expect(throws: IMAPConnectionAbortedError()) { _ = try await old.noop() }

            try await server.connect()
            await #expect(throws: IMAPConnectionAbortedError()) { _ = try await old.noop() }
            let fresh = try await server.connection(named: "x")
            #expect(fresh !== old)
            _ = try await fresh.noop()
            try await old.connect()
            _ = try await old.noop()
        }
    }
}

// MARK: - Dedicated IDLE sessions

extension IMAPIdleGroupLifecycleTests {
    @Test(arguments: ["tcp", "greeting", "auth", "select"], [false, true])
    func invalidationDuringDedicatedBootstrapAllowsNoLaterStep(stage: String, viaDisconnect: Bool) async throws {
        let gate = HoldGate("tcp")
        defer { gate.release.signal() }
        let scripts = ManagedSessionFixture.heldReply(stage, connection: 2)
        try await ManagedSessionFixture.run(scripts: scripts) { fixture in
            let server = fixture.server
            if stage == "tcp" { await fixture.holdFirstManagedConnection(at: gate) }
            let idle = Task { try await server.idle(on: "INBOX", configuration: ManagedSessionFixture.fastIdle) }
            var held: IMAPTestServer.Event?
            if stage == "tcp" {
                await gate.entered.wait()
            } else {
                held = try await fixture.event(
                    .replyHeld, connection: 2, occurrence: ManagedSessionFixture.heldOccurrence(stage))
            }

            if viaDisconnect {
                try await authenticationResult(Task { try await server.disconnect() })
            } else {
                await server.invalidateManagedSession()
            }
            await #expect(throws: IMAPConnectionAbortedError()) { try await authenticationResult(idle) }
            try await fixture.eof(2)
            let commandsAtAbort = fixture.commands(on: 2)

            if let held { #expect(try !fixture.release(held, gate: stage)) }
            gate.release.signal()
            if stage == "tcp" { await gate.exited.wait() }
            #expect(await server.idleConnections.isEmpty)
            if !viaDisconnect {
                await #expect(throws: IMAPConnectionAbortedError()) {
                    _ = try await server.idle(on: "INBOX", configuration: ManagedSessionFixture.fastIdle)
                }
            }
            #expect(fixture.commands(on: 2) == commandsAtAbort)
            #expect(!commandsAtAbort.contains { $0.hasSuffix("IDLE") })
            #expect(fixture.testServer.idleCommandCount == 0)
            #expect(fixture.testServer.acceptedConnectionCount == 2)
        }
    }

    /// The IDLE socket (2) closes; recovery dials 3 and is held there. Stopping the
    /// session — terminally or with `done()` — does not wait for the held step and
    /// allows no later dial, authentication, SELECT or IDLE.
    @Test(arguments: [("greeting", false), ("auth", false), ("select", false), ("greeting", true), ("select", true)])
    func stoppingDuringDedicatedRecoveryAllowsNoLaterStep(stage: String, viaDone: Bool) async throws {
        let scripts = [IMAPTestServer.Script(connectionNumber: 2, occurrence: 6, actions: [
            .send(Data("+ idling\r\n".utf8), acknowledgement: "idling"), .close
        ])] + ManagedSessionFixture.heldReply(stage, connection: 3)
        try await ManagedSessionFixture.run(scripts: scripts) { fixture in
            let server = fixture.server
            let session = try await server.idle(on: "INBOX", configuration: ManagedSessionFixture.fastIdle)
            let held = try await fixture.event(
                .replyHeld, connection: 3, occurrence: ManagedSessionFixture.heldOccurrence(stage))

            if viaDone {
                try await authenticationResult(Task { try await session.done() })
            } else {
                await server.invalidateManagedSession()
            }
            try await fixture.eof(3)
            try await streamFinishes(session)
            let commandsAtStop = fixture.commands(on: 3)
            #expect(try !fixture.release(held, gate: stage))

            // Repeated stops are no-ops.
            try await session.done()
            await server.invalidateManagedSession()
            try await server.disconnect()
            #expect(fixture.commands(on: 3) == commandsAtStop)
            #expect(fixture.testServer.idleCommandCount == 1)
            #expect(fixture.testServer.acceptedConnectionCount == 3)
        }
    }

    /// Primary-only invalidation leaves named and dedicated work running.
    @Test
    func primaryInvalidationLeavesNamedAndDedicatedSiblings() async throws {
        try await ManagedSessionFixture.run { fixture in
            let server = fixture.server
            let named = try await server.connection(named: "sibling")
            let session = try await server.idle(on: "INBOX", configuration: ManagedSessionFixture.fastIdle)
            await server.invalidatePrimaryConnection()
            try await fixture.eof(1)
            await #expect(throws: IMAPConnectionAbortedError()) { _ = try await server.noop() }

            _ = try await named.noop()
            #expect(await server.idleConnections.count == 1)
            #expect(await server.namedConnections["sibling"]?.handle === named)
            #expect(!fixture.testServer.events.contains {
                $0.kind == .peerEOF && $0.connection.number != 1
            })

            // Ending the dedicated session does not touch the named sibling either.
            try await session.done()
            try await fixture.eof(3)
            _ = try await named.noop()
            try await server.connect()
            try await server.login(username: "u", password: "p")
            _ = try await server.noop()
        }
    }

    /// Connections: 1 primary, 2 old session, 3 primary after rearm, 4 new session.
    @Test
    func oldSessionCleanupAfterRearmLeavesTheNewSession() async throws {
        try await ManagedSessionFixture.run { fixture in
            let server = fixture.server
            let old = try await server.idle(on: "INBOX", configuration: ManagedSessionFixture.fastIdle)
            await server.invalidateManagedSession()
            try await fixture.eof(2)
            try await streamFinishes(old)

            try await server.connect()
            let fresh = try await server.idle(on: "INBOX", configuration: ManagedSessionFixture.fastIdle)
            _ = try await fixture.event(.commandReachedServer, connection: 4, occurrence: 6)
            try await old.done()
            #expect(await server.idleConnections.count == 1)
            #expect(!fixture.testServer.events.contains { $0.kind == .peerEOF && $0.connection.number == 4 })

            try await fresh.done()
            try await fixture.eof(4)
            try await streamFinishes(fresh)
            #expect(await server.idleConnections.isEmpty)
        }
    }
}
#endif
