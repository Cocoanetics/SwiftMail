import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SMTPTransportSecurityTests {
    @Test
    func explicitSTARTTLSRequiresAdvertisedUpgrade() {
        #expect(
            SMTPServer.requiresSTARTTLSUpgrade(
                transportMode: .startTLSRequired,
                capabilities: ["SIZE", "STARTTLS", "AUTH PLAIN"]
            )
        )
    }

    @Test
    func explicitSTARTTLSRequiresMissingSTARTTLSErrorWhenNotAdvertised() {
        #expect(
            SMTPServer.requiresMissingSTARTTLSError(
                transportMode: .startTLSRequired,
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )
    }

    @Test
    func implicitTLSSkipsSTARTTLSPolicyHelpers() {
        #expect(
            !SMTPServer.requiresSTARTTLSUpgrade(
                transportMode: .implicitTLS,
                capabilities: ["SIZE", "STARTTLS", "AUTH PLAIN"]
            )
        )

        #expect(
            !SMTPServer.requiresMissingSTARTTLSError(
                transportMode: .implicitTLS,
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )
    }

    @Test
    func automaticTransportSecurityPreservesPortInferredBehavior() {
        #expect(SMTPServer.resolveTransportMode(port: 465, transportSecurity: .automatic) == .implicitTLS)
        #expect(SMTPServer.resolveTransportMode(port: 587, transportSecurity: .automatic) == .startTLSIfAvailable)
        #expect(SMTPServer.resolveTransportMode(port: 1025, transportSecurity: .automatic) == .plainText)
    }

    @Test
    func automatic587DoesNotRequireSTARTTLSWhenCapabilityIsMissing() {
        let transportMode = SMTPServer.resolveTransportMode(port: 587, transportSecurity: .automatic)

        #expect(
            !SMTPServer.requiresMissingSTARTTLSError(
                transportMode: transportMode,
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )
    }

    @Test
    func automatic587RequestsSTARTTLSWhenCapabilityIsAdvertised() {
        let transportMode = SMTPServer.resolveTransportMode(port: 587, transportSecurity: .automatic)

        #expect(
            SMTPServer.requiresSTARTTLSUpgrade(
                transportMode: transportMode,
                capabilities: ["SIZE", "STARTTLS", "AUTH PLAIN"]
            )
        )
    }
}
