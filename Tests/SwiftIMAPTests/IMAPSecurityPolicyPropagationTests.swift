import Testing
import Foundation
import NIO
import NIOIMAPCore
@testable import SwiftMail

/// Does an `IMAPServer`'s security policy reach the connections it spawns?
///
/// `IMAPServer` documents `minimumTLSVersion` and `parserLimits` as server-level policy. They
/// were applied to the primary connection only: `makeIdleConnection` and `makeNamedConnection`
/// left both out, so a caller with a TLS 1.3 floor and 64 MiB parser limits got a TLS 1.2 floor
/// and *unbounded* limits the moment IDLE or a named connection was used — silently, and exactly
/// where a long-lived connection listens to whatever the server chooses to send.
///
/// These assert on the spawned connection itself rather than on a factory in isolation. Remove
/// either argument from either factory and they go red.
@Suite("Server policy reaches spawned connections")
struct IMAPSecurityPolicyPropagationTests {

    private func makeServer() -> SwiftMail.IMAPServer {
        SwiftMail.IMAPServer(
            host: "imap.example.com",
            port: 993,
            minimumTLSVersion: MailTLSMinimumVersion.tlsv13,
            parserLimits: IMAPParserLimits(
                bodySizeLimit: 64 * 1024 * 1024,
                messageAttributeLimit: 1024
            )
        )
    }

    @Test("Named connections inherit the TLS floor and the parser limits")
    func namedConnectionInheritsPolicy() async {
        let connection = await makeServer().makeNamedConnection(name: "sync")
        #expect(connection.minimumTLSVersion == MailTLSMinimumVersion.tlsv13)
        #expect(connection.parserLimits.bodySizeLimit == 64 * 1024 * 1024)
        #expect(connection.parserLimits.messageAttributeLimit == 1024)
    }

    @Test("IDLE connections inherit the TLS floor and the parser limits")
    func idleConnectionInheritsPolicy() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let connection = await makeServer().makeIdleConnection(
            sessionID: UUID(), mailbox: "INBOX", group: group
        )
        #expect(connection.minimumTLSVersion == MailTLSMinimumVersion.tlsv13)
        #expect(connection.parserLimits.bodySizeLimit == 64 * 1024 * 1024)
        #expect(connection.parserLimits.messageAttributeLimit == 1024)
    }
}

/// Do the documented limits mean what they say?
///
/// `IMAPParserLimits` documents its properties as *maxima*. The pinned parser enforces strict
/// inequalities (`size < bodySizeLimit`, `attributeCount < messageAttributeLimit`, the latter
/// checked again on the FETCH closing delimiter), so passing the values through unchanged made
/// the effective maximum one less than the documented one: a 64 MiB limit rejected a message of
/// exactly 64 MiB.
@Suite("Parser limits are inclusive maxima")
struct IMAPParserLimitsTranslationTests {

    @Test("A body of exactly the documented maximum is still allowed")
    func bodyLimitIsInclusive() {
        let limits = IMAPParserLimits(bodySizeLimit: 64 * 1024 * 1024)
        let options = limits.makeParserOptions(bufferLimit: 1024)
        // The parser rejects `size >= bodySizeLimit`, so accepting exactly 64 MiB needs 64 MiB + 1.
        #expect(options.bodySizeLimit == 64 * 1024 * 1024 + 1)
    }

    @Test("A FETCH with exactly the documented number of attributes is still allowed")
    func attributeLimitIsInclusive() {
        let options = IMAPParserLimits(messageAttributeLimit: 1024).makeParserOptions(bufferLimit: 1024)
        #expect(options.messageAttributeLimit == 1025)
    }

    /// The `+ 1` must saturate: the defaults are `.max`, where `+ 1` would trap — and `.max`
    /// already means unbounded, so there is nothing to widen.
    @Test("Unbounded defaults do not overflow")
    func defaultsDoNotOverflow() {
        let options = IMAPParserLimits.default.makeParserOptions(bufferLimit: 1024)
        #expect(options.bodySizeLimit == .max)
        #expect(options.messageAttributeLimit == .max)
    }

    @Test("The buffer limit is passed through untouched — it bounds a different thing")
    func bufferLimitIsUnchanged() {
        let options = IMAPParserLimits.default.makeParserOptions(bufferLimit: 4096)
        #expect(options.bufferLimit == 4096)
    }
}
