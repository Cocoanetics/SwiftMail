#if os(macOS)
import Foundation
import Testing
@testable import SwiftMail

/// logout() ends every connection the server holds, whether or not LOGOUT itself could be
/// sent, and never dials a new connection to do it. Connection 1 is the primary,
/// connection 2 a named connection; a connection 3 would be one opened just to log out.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LogoutClosesAllConnectionsTests {
    /// Occurrences on the primary: greeting 0, CAPABILITY 1, LOGIN 2, CAPABILITY 3,
    /// NAMESPACE 4, then NOOP 5 (sent below), LOGOUT 6.
    private static let primaryLogoutOccurrence = 6

    @Test
    func liveSessionIsLoggedOutAndEveryConnectionCloses() async throws {
        try await ManagedSessionFixture.run { fixture in
            let named = try await openNamedConnection(fixture)

            try await fixture.server.logout()

            #expect(fixture.commands(on: 1).last?.hasSuffix(" LOGOUT") == true)
            try await expectEveryConnectionClosed(fixture, named: named)
        }
    }

    @Test
    func closedPrimaryIsNotReopenedAndEveryConnectionStillCloses() async throws {
        try await ManagedSessionFixture.run { fixture in
            let named = try await openNamedConnection(fixture)
            let primary = await fixture.server.primaryConnection
            try await primary.channel?.close()

            try await fixture.server.logout()

            #expect(!fixture.commands(on: 1).contains { $0.hasSuffix(" LOGOUT") })
            try await expectEveryConnectionClosed(fixture, named: named)
        }
    }

    /// The connection closes while LOGOUT is in flight: logout() reports that failure,
    /// and the other connections are closed all the same.
    @Test
    func connectionClosedDuringLogoutStillClosesEveryConnection() async throws {
        let closeOnLogout = IMAPTestServer.Script(
            connectionNumber: 1, occurrence: Self.primaryLogoutOccurrence, actions: [.close]
        )
        try await ManagedSessionFixture.run(scripts: [closeOnLogout]) { fixture in
            let named = try await openNamedConnection(fixture)

            await #expect(throws: (any Error).self) { try await fixture.server.logout() }

            #expect(fixture.commands(on: 1).last?.hasSuffix(" LOGOUT") == true)
            try await expectEveryConnectionClosed(fixture, named: named)
        }
    }

    private func openNamedConnection(_ fixture: ManagedSessionFixture) async throws -> IMAPNamedConnection {
        _ = try await fixture.server.noop()
        let named = try await fixture.server.connection(named: "worker")
        _ = try await named.noop()
        #expect(await named.isConnected)
        return named
    }

    private func expectEveryConnectionClosed(
        _ fixture: ManagedSessionFixture, named: IMAPNamedConnection
    ) async throws {
        let namedEnded = (try? await fixture.testServer.waitForConnectionEnd(
            run: fixture.testServer.runID, connection: fixture.testServer.connection(2), timeout: 5)) != nil
        #expect(namedEnded, "the named connection must be closed by logout()")
        #expect(!(await named.isConnected))
        #expect(!(await fixture.server.isConnected))
        let third = fixture.testServer.connection(3)
        #expect(!fixture.testServer.events.contains { $0.connection == third }, "no connection may be opened")
        // Ends whatever logout() left open, so a failing run ends instead of hanging the fixture.
        try? await fixture.server.disconnect()
    }
}
#endif
