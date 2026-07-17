import Foundation
import NIO
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPResponseBufferLimitTests {
    // Group shutdown goes through the shared shutDownGracefully(_:) helper in
    // EventLoopGroupTestSupport.swift; this suite's private GCD-dispatch copy was
    // its first iteration and parked a thread in the pool that delivers the
    // shutdown's own completion — see the helper's comment for the full story.

    @Test("Default response buffer limit is 1 MB")
    func defaultIsOneMegabyte() async {
        let server = IMAPServer(host: "imap.example.com", port: 993)
        let limit = await server.primaryResponseBufferLimitForTesting
        #expect(IMAPServer.defaultResponseBufferLimit == 1024 * 1024)
        #expect(limit == IMAPServer.defaultResponseBufferLimit)
    }

    @Test("Custom limit propagates to the primary connection")
    func customLimitPropagatesToPrimary() async {
        let custom = 4 * 1024 * 1024
        let server = IMAPServer(
            host: "imap.example.com",
            port: 993,
            responseBufferLimit: custom
        )
        let limit = await server.primaryResponseBufferLimitForTesting
        #expect(limit == custom)
    }

    @Test("Legacy useTLS initializer honors a custom limit")
    func legacyInitHonorsCustomLimit() async {
        let custom = 2 * 1024 * 1024
        let server = IMAPServer(
            host: "imap.example.com",
            port: 993,
            useTLS: true,
            numberOfThreads: 1,
            responseBufferLimit: custom
        )
        let limit = await server.primaryResponseBufferLimitForTesting
        #expect(limit == custom)
    }

    // Spawned idle/named connections forward the same `responseBufferLimit`
    // value the server was configured with; verifying the connection-level
    // plumbing here (without crossing the actor boundary with a non-Sendable
    // IMAPConnection) covers what those one-line forwarders rely on.
    @Test("Directly constructed connection defaults to 1 MB")
    func directConnectionDefault() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connection = IMAPConnection(
            host: "localhost",
            port: 993,
            useTLS: true,
            group: group,
            loggerLabel: "test.imap",
            outboundLabel: "test.imap.out",
            inboundLabel: "test.imap.in",
            connectionID: "test-default-buffer",
            connectionRole: "test"
        )
        #expect(connection.responseBufferLimitForTesting == IMAPServer.defaultResponseBufferLimit)
        await shutDownGracefully(group)
    }

    @Test("Directly constructed connection honors a custom limit")
    func directConnectionCustom() async {
        let custom = 3 * 1024 * 1024
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connection = IMAPConnection(
            host: "localhost",
            port: 993,
            useTLS: true,
            group: group,
            loggerLabel: "test.imap",
            outboundLabel: "test.imap.out",
            inboundLabel: "test.imap.in",
            connectionID: "test-custom-buffer",
            connectionRole: "test",
            responseBufferLimit: custom
        )
        #expect(connection.responseBufferLimitForTesting == custom)
        await shutDownGracefully(group)
    }
}
