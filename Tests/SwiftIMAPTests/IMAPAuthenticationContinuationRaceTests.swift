import NIOIMAPCore
import Testing
@testable import SwiftMail

extension IMAPBootstrapRaceTests {
    @Test(arguments: ["PLAIN", "XOAUTH2"])
    func abortWhileAuthenticationContinuationWriteIsHeld(mechanismName: String) async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let channel = try await installTransport(connection)
            let writeGate = AuthenticationContinuationWriteGate()
            try await channel.pipeline.addHandler(writeGate, position: .before(connection.duplexLogger))
            defer { connection.abortNow() }

            let method: SwiftMail.IMAPServer.AuthenticationMethod
            if mechanismName == "PLAIN" {
                method = .plain(username: "user", password: "secret")
                connection.replaceCapabilitiesForTesting([.authenticate(.plain)])
            } else {
                let xoauth2 = AuthenticationMechanism("XOAUTH2")!
                method = .xoauth2(email: "user@example.com", accessTokenProvider: { "token" })
                connection.replaceCapabilitiesForTesting([.authenticate(xoauth2)])
            }

            let authentication = SwiftMail.IMAPServer.Authentication(method: method)
            let authenticating = Task { try await authentication.authenticate(on: connection) }
            #expect(try await outbound(channel).contains("AUTHENTICATE \(mechanismName)"))
            try await inbound(channel, "+ \r\n")
            await writeGate.entered.wait()

            connection.abortNow()
            await #expect(throws: IMAPAbortReason.connectionAborted) { try await authenticating.value }
            try await writeGate.failHeldWrite()
            try await channel.closeFuture.get()
            #expect(connection.channel == nil)
        }
    }
}
