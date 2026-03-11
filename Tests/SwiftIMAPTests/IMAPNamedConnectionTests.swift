import Foundation
import NIO
import NIOIMAPCore
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

    @Test
    func uidExpungeRequiresUIDPlusCapability() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            Task {
                try? await group.shutdownGracefully()
            }
        }

        let connection = IMAPConnection(
            host: "localhost",
            port: 1,
            group: group,
            loggerLabel: "test.imap",
            outboundLabel: "test.imap.out",
            inboundLabel: "test.imap.in",
            connectionID: "test-uidexpunge",
            connectionRole: "test"
        )
        connection.replaceCapabilitiesForTesting([])
        let named = IMAPNamedConnection(name: "test", connection: connection, authenticateOnConnection: { _ in })

        do {
            try await named.uidExpunge(messages: UIDSet(UID(7)))
            Issue.record("Expected UID EXPUNGE to require UIDPLUS")
        } catch let error as IMAPError {
            guard case .commandNotSupported(let message) = error else {
                Issue.record("Expected commandNotSupported, got \(error)")
                return
            }
            #expect(message == "UID EXPUNGE command not supported by server")
        } catch {
            Issue.record("Expected IMAPError.commandNotSupported, got \(error)")
        }
    }
}
