import Foundation
import NIO
import NIOIMAPCore
import Testing
@testable import SwiftMail

/// `supportsGmailExtensions` must honour RFC 3501's case-insensitive capability
/// names on both surfaces. NIOIMAPCore preserves the server's spelling and
/// synthesizes case-sensitive `Capability` equality, so a server or proxy
/// advertising `x-gm-ext-1` was reported unsupported and callers following the
/// documented gate skipped `fetchGmailAttributes`.
@Suite("Gmail extensions capability detection", .serialized, .timeLimit(.minutes(1)))
struct GmailExtensionsCapabilityTests {
    private static let spellings: [NIOIMAPCore.Capability] = [
        .gmailExtensions,
        Capability("x-gm-ext-1"),
        Capability("X-Gm-Ext-1")
    ]

    // MARK: - IMAPServer

    @Test("Server reports Gmail extensions unsupported when they are not advertised")
    func serverWithoutGmailExtensions() async {
        let server = await makeServer(capabilities: [.idle, .move, .namespace])
        #expect(await server.supportsGmailExtensions == false)
    }

    @Test("Server accepts every spelling of X-GM-EXT-1")
    func serverAcceptsEverySpelling() async {
        for spelling in Self.spellings {
            let server = await makeServer(capabilities: [.idle, spelling])
            #expect(await server.supportsGmailExtensions, "spelling \(spelling)")
        }
    }

    // MARK: - IMAPNamedConnection

    @Test("Named connection reports Gmail extensions unsupported when they are not advertised")
    func namedConnectionWithoutGmailExtensions() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let named = makeNamedConnection(capabilities: [.idle, .uidPlus], group: group)
        #expect(await named.supportsGmailExtensions == false)
    }

    @Test("Named connection accepts every spelling of X-GM-EXT-1")
    func namedConnectionAcceptsEverySpelling() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        for spelling in Self.spellings {
            let named = makeNamedConnection(capabilities: [.idle, spelling], group: group)
            #expect(await named.supportsGmailExtensions, "spelling \(spelling)")
        }
    }

    // MARK: - Helpers

    private func makeServer(capabilities: Set<NIOIMAPCore.Capability>) async -> SwiftMail.IMAPServer {
        let server = SwiftMail.IMAPServer(host: "imap.example.com", port: 993)
        await server.primaryConnection.replaceCapabilitiesForTesting(capabilities)
        return server
    }

    private func makeNamedConnection(
        capabilities: Set<NIOIMAPCore.Capability>,
        group: MultiThreadedEventLoopGroup
    ) -> IMAPNamedConnection {
        let connection = IMAPConnection(
            host: "localhost",
            port: 1,
            useTLS: false,
            group: group,
            loggerLabel: "test.imap",
            outboundLabel: "test.imap.out",
            inboundLabel: "test.imap.in",
            connectionID: "test-gmail-capability",
            connectionRole: "test"
        )
        connection.replaceCapabilitiesForTesting(capabilities)
        return IMAPNamedConnection(name: "test", connection: connection, authenticateOnConnection: { _ in })
    }
}
