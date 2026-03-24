import Testing
import NIOIMAPCore
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct AppendLimitTests {

    // MARK: - globalAppendLimit extraction

    @Test("Returns nil when capability set is empty")
    func globalAppendLimit_emptySet() {
        let caps: Set<NIOIMAPCore.Capability> = []
        #expect(caps.globalAppendLimit == nil)
    }

    @Test("Returns nil when only bare APPENDLIMIT (no value) is present")
    func globalAppendLimit_bareCapability() {
        // .mailboxSpecificAppendLimit == "APPENDLIMIT" with no value
        let caps: Set<NIOIMAPCore.Capability> = [.mailboxSpecificAppendLimit]
        #expect(caps.globalAppendLimit == nil)
    }

    @Test("Returns correct limit when APPENDLIMIT=<n> is advertised")
    func globalAppendLimit_withValue() {
        let caps: Set<NIOIMAPCore.Capability> = [.appendLimit(10_485_760)]
        #expect(caps.globalAppendLimit == 10_485_760)
    }

    @Test("Returns limit ignoring other capabilities in the set")
    func globalAppendLimit_mixedCapabilities() {
        let caps: Set<NIOIMAPCore.Capability> = [
            .uidPlus,
            .idle,
            .appendLimit(5_000_000),
            .move,
        ]
        #expect(caps.globalAppendLimit == 5_000_000)
    }

    @Test("Returns nil when APPENDLIMIT is absent but other capabilities exist")
    func globalAppendLimit_absent() {
        let caps: Set<NIOIMAPCore.Capability> = [.uidPlus, .idle, .move]
        #expect(caps.globalAppendLimit == nil)
    }

    // MARK: - IMAPError.appendLimitExceeded descriptions

    @Test("Error description includes payload and limit sizes")
    func appendLimitExceeded_description() {
        let error = IMAPError.appendLimitExceeded(6_000_000, 5_000_000)
        let desc = error.description
        #expect(desc.contains("6000000"))
        #expect(desc.contains("5000000"))
    }

    @Test("errorDescription is non-nil and matches description")
    func appendLimitExceeded_errorDescription() {
        let error = IMAPError.appendLimitExceeded(1024, 512)
        #expect(error.errorDescription == error.description)
    }

    @Test("failureReason is non-nil for appendLimitExceeded")
    func appendLimitExceeded_failureReason() {
        let error = IMAPError.appendLimitExceeded(2048, 1024)
        #expect(error.failureReason != nil)
    }
}
