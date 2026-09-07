import Foundation
import NIO
import NIOIMAPCore
import Testing
@testable import SwiftMail

/// Does the public MOVE capability accessor report what the server actually advertised?
///
/// `supportsUIDPlus` was public while the MOVE capability was only visible through the
/// `internal` `capabilities` set, so a caller could not decide for itself whether to issue a
/// `MOVE` (RFC 6851) or to drive COPY + STORE `\Deleted` + EXPUNGE and own the resulting UID
/// bookkeeping. These pin the accessor to the MOVE capability specifically: the interesting
/// failure is not "always false", it is a copy-paste that leaves the body reading `.uidPlus`,
/// which stays green against any server advertising both. The mixed-capability and
/// not-aliased cases separate the two so that substitution goes red.
@Suite("MOVE capability detection", .serialized, .timeLimit(.minutes(1)))
struct MoveCapabilityTests {

    // MARK: - IMAPServer

    @Test("Server reports MOVE unsupported when it is not advertised")
    func serverWithoutMoveReportsUnsupported() async {
        let server = await makeServer(capabilities: [])
        #expect(await server.supportsMove == false)
    }

    @Test("Server reports MOVE supported when it is advertised")
    func serverWithMoveReportsSupported() async {
        let server = await makeServer(capabilities: [.move])
        #expect(await server.supportsMove)
    }

    @Test("Server MOVE support is independent of UIDPLUS")
    func serverMoveIsNotAliasedToUIDPlus() async {
        // UIDPLUS alone must not imply MOVE …
        let uidPlusOnly = await makeServer(capabilities: [.uidPlus])
        #expect(await uidPlusOnly.supportsMove == false)
        #expect(await uidPlusOnly.supportsUIDPlus)

        // … and MOVE alone must not imply UIDPLUS.
        let moveOnly = await makeServer(capabilities: [.move])
        #expect(await moveOnly.supportsMove)
        #expect(await moveOnly.supportsUIDPlus == false)
    }

    @Test("Server finds MOVE among unrelated capabilities")
    func serverMoveAmongMixedCapabilities() async {
        let server = await makeServer(capabilities: [.idle, .move, .namespace])
        #expect(await server.supportsMove)
    }

    // MARK: - IMAPNamedConnection

    @Test("Named connection reports MOVE unsupported when it is not advertised")
    func namedConnectionWithoutMove() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let named = makeNamedConnection(capabilities: [], group: group)
        #expect(await named.supportsMove == false)
        await shutDownGracefully(group)
    }

    @Test("Named connection reports MOVE supported when it is advertised")
    func namedConnectionWithMove() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let named = makeNamedConnection(capabilities: [.move], group: group)
        #expect(await named.supportsMove)
        await shutDownGracefully(group)
    }

    @Test("Named connection MOVE support is independent of UIDPLUS")
    func namedMoveIsNotAliasedToUIDPlus() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let uidPlusOnly = makeNamedConnection(capabilities: [.uidPlus], group: group)
        #expect(await uidPlusOnly.supportsMove == false)
        #expect(await uidPlusOnly.supportsUIDPlus)

        let moveOnly = makeNamedConnection(capabilities: [.move], group: group)
        #expect(await moveOnly.supportsMove)
        #expect(await moveOnly.supportsUIDPlus == false)

        await shutDownGracefully(group)
    }

    // MARK: - Helpers

    /// Builds an unconnected `IMAPServer` whose primary connection advertises `capabilities`.
    ///
    /// The server owns an internally created `EventLoopGroup` it never exposes; no transport is
    /// opened here, matching the existing unconnected-server suites.
    private func makeServer(capabilities: Set<NIOIMAPCore.Capability>) async -> SwiftMail.IMAPServer {
        let server = SwiftMail.IMAPServer(host: "imap.example.com", port: 993)
        await server.primaryConnection.replaceCapabilitiesForTesting(capabilities)
        return server
    }

    /// Builds an unconnected `IMAPNamedConnection` advertising `capabilities` on `group`.
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
            connectionID: "test-move-capability",
            connectionRole: "test"
        )
        connection.replaceCapabilitiesForTesting(capabilities)
        return IMAPNamedConnection(name: "test", connection: connection, authenticateOnConnection: { _ in })
    }
}
