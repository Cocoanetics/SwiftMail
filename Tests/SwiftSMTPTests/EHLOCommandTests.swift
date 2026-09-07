import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct EHLOCommandTests {
    @Test
    func clientIdentityRejectsSMTPCommandInjection() {
        let command = EHLOCommand(clientIdentity: "mail.example.com\r\nNOOP")

        #expect(throws: SMTPError.self) {
            try command.validate()
        }
    }

    @Test
    func clientIdentityAcceptsRFC5321DomainsAndAddressLiterals() {
        let identities = [
            "localhost",
            "mail.example.com",
            "mail-gateway.example.com",
            "[127.0.0.1]",
            "[IPv6:2001:db8::1]"
        ]

        for identity in identities {
            #expect(throws: Never.self, "Expected \(identity) to be accepted") {
                try EHLOCommand(clientIdentity: identity).validate()
            }
        }
    }

    @Test
    func clientIdentityRejectsMalformedDomainsAndAddressLiterals() {
        let identities = [
            "client_name",
            ".example.com",
            "example.com.",
            "-mail.example.com",
            "mail-.example.com",
            "mail..example.com",
            String(repeating: "a", count: 64) + ".example.com",
            "[127.0.0.256]",
            "[IPv6:not-an-address]",
            "[example:opaque-value]",
            "[example:]",
            "[example:bad\\content]"
        ]

        for identity in identities {
            #expect(throws: SMTPError.self, "Expected \(identity) to be rejected") {
                try EHLOCommand(clientIdentity: identity).validate()
            }
        }
    }

    #if os(macOS) || os(Linux)
    @Test
    func invalidClientIdentityFailsConnectWithoutRetainingChannel() async throws {
        let testServer = SMTPTestServer()
        try testServer.start()

        try await testServer.run {
            let client = SMTPServer(
                host: "127.0.0.1",
                port: testServer.port,
                transportSecurity: .plainText,
                clientIdentity: "bad identity"
            )

            await #expect(throws: SMTPError.self) {
                try await client.connect()
            }
            #expect(await !client.hasChannelForTesting)
            #expect(testServer.recordedCommands.isEmpty)
        }
    }
    #endif
}
