import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SMTPTransportSecurityTests {
    @Test
    func explicitSTARTTLSRequiresAdvertisedUpgrade() {
        #expect(
            SMTPServer.requiresSTARTTLSUpgrade(
                transportSecurity: .startTLS,
                capabilities: ["SIZE", "STARTTLS", "AUTH PLAIN"]
            )
        )
    }

    @Test
    func explicitSTARTTLSRequiresMissingSTARTTLSErrorWhenNotAdvertised() {
        #expect(
            SMTPServer.requiresMissingSTARTTLSError(
                transportSecurity: .startTLS,
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )
    }

    @Test
    func implicitTLSSkipsSTARTTLSPolicyHelpers() {
        #expect(
            !SMTPServer.requiresSTARTTLSUpgrade(
                transportSecurity: .implicitTLS,
                capabilities: ["SIZE", "STARTTLS", "AUTH PLAIN"]
            )
        )

        #expect(
            !SMTPServer.requiresMissingSTARTTLSError(
                transportSecurity: .implicitTLS,
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )
    }

    @Test
    func automaticTransportSecurityPreservesPortInferredBehavior() {
        #expect(SMTPServer.resolveTransportSecurity(port: 465, transportSecurity: .automatic) == .implicitTLS)
        #expect(SMTPServer.resolveTransportSecurity(port: 587, transportSecurity: .automatic) == .startTLS)
        #expect(SMTPServer.resolveTransportSecurity(port: 1025, transportSecurity: .automatic) == .plainText)
    }
}
