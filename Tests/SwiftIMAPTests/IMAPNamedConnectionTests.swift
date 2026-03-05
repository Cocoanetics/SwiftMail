import Foundation
import NIO
import Testing
@testable import SwiftMail

struct IMAPNamedConnectionTests {
    private func makeConnection(name: String = "test", authenticate: @escaping @Sendable (IMAPConnection) async throws -> Void = { _ in }) -> IMAPNamedConnection {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connection = IMAPConnection(
            host: "localhost",
            port: 1,
            group: group,
            loggerLabel: "test.imap",
            outboundLabel: "test.imap.out",
            inboundLabel: "test.imap.in",
            connectionID: "test-\(name)",
            connectionRole: "test"
        )
        return IMAPNamedConnection(name: name, connection: connection, authenticateOnConnection: authenticate)
    }

    @Test
    func lastActivityIsNilBeforeAnyCommands() async {
        let named = makeConnection()
        let activity = await named.lastActivity
        #expect(activity == nil)
    }

    @Test
    func lastActivityRemainsNilAfterFailedCommand() async {
        // Authentication closure throws, so executeCommand never reaches the
        // connection.executeCommand(_:) call, and lastActivity must stay nil.
        let named = makeConnection(authenticate: { _ in
            throw IMAPError.authFailed("auth error")
        })

        do {
            try await named.fetchCapabilities()
        } catch {
            // expected – authentication throws before any command reaches the server
        }

        let activity = await named.lastActivity
        #expect(activity == nil)
    }
}
