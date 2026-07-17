import Testing
import NIOIMAPCore
@testable import SwiftMail

/// - Note: `.serialized` and `.timeLimit` match the other server-constructing suites.
///   Constructing an `IMAPServer` or `SMTPServer` allocates a `MultiThreadedEventLoopGroup`
///   that is shut down on release; suites that release servers used to be able to deadlock a
///   core-constrained CI runner when the deinit still *blocked* on that shutdown, so the traits
///   keep server churn serialized and bounded in time as defense in depth.
@Suite("IMAP parser limits", .serialized, .timeLimit(.minutes(1)))
struct IMAPParserLimitsTests {

    @Test("Defaults preserve the previous unbounded behaviour")
    func defaultsAreUnbounded() {
        let limits = IMAPParserLimits.default
        #expect(limits.bodySizeLimit == UInt64.max)
        #expect(limits.messageAttributeLimit == Int.max)
        #expect(limits.literalSizeLimit == IMAPDefaults.literalSizeLimit)
    }

    @Test("Caller-supplied bounds are kept")
    func customLimits() {
        let limits = IMAPParserLimits(
            bodySizeLimit: 64 * 1024 * 1024,
            messageAttributeLimit: 1024,
            literalSizeLimit: 8192
        )
        #expect(limits.bodySizeLimit == 64 * 1024 * 1024)
        #expect(limits.messageAttributeLimit == 1024)
        #expect(limits.literalSizeLimit == 8192)
    }

    @Test("Each field can be tightened on its own")
    func partialOverride() {
        let limits = IMAPParserLimits(bodySizeLimit: 1024)
        #expect(limits.bodySizeLimit == 1024)
        #expect(limits.messageAttributeLimit == Int.max)
        #expect(limits.literalSizeLimit == IMAPDefaults.literalSizeLimit)
    }

    @Test("IMAPServer carries the caller's limits")
    func imapServerStoresLimits() async {
        let limits = IMAPParserLimits(bodySizeLimit: 32 * 1024 * 1024, messageAttributeLimit: 512)
        let server = IMAPServer(host: "imap.example.com", port: 993, parserLimits: limits)
        #expect(await server.parserLimits == limits)
    }

    @Test("IMAPServer defaults to the unbounded limits")
    func imapServerDefault() async {
        let server = IMAPServer(host: "imap.example.com", port: 993)
        #expect(await server.parserLimits == .default)
    }

    @Test("Limits are value-comparable")
    func equatable() {
        #expect(IMAPParserLimits(bodySizeLimit: 100) == IMAPParserLimits(bodySizeLimit: 100))
        #expect(IMAPParserLimits(bodySizeLimit: 100) != IMAPParserLimits(bodySizeLimit: 200))
    }
}
