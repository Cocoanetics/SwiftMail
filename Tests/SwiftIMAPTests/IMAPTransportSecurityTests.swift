import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPTransportSecurityTests {
    @Test
    func explicitStartTLSRequiresUpgradeOnArbitraryPorts() throws {
        let mode = IMAPConnection.resolveTLSTransportMode(port: 1143, transportSecurity: .startTLS)

        #expect(mode == .startTLSRequired)
    }

    @Test
    func startTLSRequiredUpgradesWhenCapabilityIsAdvertised() {
        #expect(
            IMAPConnection.requiresSTARTTLSUpgrade(
                tlsTransportMode: .startTLSRequired,
                capabilities: [.startTLS]
            )
        )
    }

    @Test
    func startTLSRequiredFailsClosedWhenCapabilityIsMissing() {
        #expect(
            IMAPConnection.requiresMissingSTARTTLSError(
                tlsTransportMode: .startTLSRequired,
                capabilities: [.idle]
            )
        )
    }

    @Test
    func explicitImplicitTLSOnArbitraryPortsSkipsStartTLS() {
        let mode = IMAPConnection.resolveTLSTransportMode(port: 1143, transportSecurity: .implicitTLS)

        #expect(mode == .implicitTLS)
        #expect(
            !IMAPConnection.requiresSTARTTLSUpgrade(
                tlsTransportMode: mode,
                capabilities: [.startTLS]
            )
        )
    }

    @Test
    func automaticPreservesStandardIMAPPortBehavior() {
        #expect(
            IMAPConnection.resolveTLSTransportMode(port: 993, transportSecurity: .automatic) == .implicitTLS
        )
        #expect(
            IMAPConnection.resolveTLSTransportMode(port: 143, transportSecurity: .automatic) == .startTLSIfAvailable
        )
    }
}
