#if os(macOS)
import Foundation
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPAbortTests {
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
