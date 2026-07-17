import Testing
import Foundation
import NIO
import NIOEmbedded
import NIOSSL
@testable import SwiftMail

// Self-signed, CN=localhost, generated for these tests only and valid for 100 years so it cannot
// rot. The client uses `.noVerification`: trust is not what is under test here, only the
// negotiated protocol version.
private let testCertPEM = """
-----BEGIN CERTIFICATE-----
MIIDCzCCAfOgAwIBAgIUXe8RGk02W2OBGgsbJaE3Jz+qGDAwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MDcxNzA2MzgwMVoYDzIxMjYw
NjIzMDYzODAxWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQC6tGyMaCTVGIleGyZy0fRdOmTzTiuzt67OYOjeZRz1
KxzfHPcx6Cm1eYv0x5WiMt6rEtv8wDEt3nxg2UQVi6NYx7NV8OVXex1dHnYmcxvv
5NrwM2f2SEKL9dZKJeNbYMeHEEPkN4HSVr/Lpw4VwhJhZx5HOTPdLbkkrNiVOXfD
nM1SahyGtPF9xpwfxZJGkdsq5CLyPEX7Vju1zumJpCV9nsR/fl9h2WsfTckYq6Pu
gvC3SKi0lW6BbNVsbmC7mPtLu8AM+9bb/3ZiDxBZiukBkP88H5Qm+Yuc5UhvTSJJ
8DlG58jAIJhX0GTr8dAKnr5Ew9xq8snHmPe9vV6yO7edAgMBAAGjUzBRMB0GA1Ud
DgQWBBTJLtTBgKxmIz00Glojehq4GEl4oTAfBgNVHSMEGDAWgBTJLtTBgKxmIz00
Glojehq4GEl4oTAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQCU
i62pqGcUlAUC/+n/zke/WGbnc20VhwqsU+lu1pOisuycvBAmtjRJJPZzWf+vQjWf
ipTv9l7QLY9924s7UcXvW9Kh0CIoqzByJeH+ZXrjqA3cNxjHbrZnnjdQ08Q0fRz7
I79wtMJeH4vvrimh+RPzuE+8AAaYu9pCxrH6X24OqMidwIICgq8zZfuL08Dlalgs
ftmQct191ESHfS6+xMejMo4tp7cJib5z5i1lInblRAKCEpTuBdwfRq0ZDf2NaRPS
2apVKzJgv/Ogi1+PRCmbGH/CtBweOEH2Jc/cC2ufO8A0ED6bI2jGLQiYiUWugLO4
Zd1/bKfP3R/4cigBAFE2
-----END CERTIFICATE-----
"""

private let testKeyPEM = """
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC6tGyMaCTVGIle
GyZy0fRdOmTzTiuzt67OYOjeZRz1KxzfHPcx6Cm1eYv0x5WiMt6rEtv8wDEt3nxg
2UQVi6NYx7NV8OVXex1dHnYmcxvv5NrwM2f2SEKL9dZKJeNbYMeHEEPkN4HSVr/L
pw4VwhJhZx5HOTPdLbkkrNiVOXfDnM1SahyGtPF9xpwfxZJGkdsq5CLyPEX7Vju1
zumJpCV9nsR/fl9h2WsfTckYq6PugvC3SKi0lW6BbNVsbmC7mPtLu8AM+9bb/3Zi
DxBZiukBkP88H5Qm+Yuc5UhvTSJJ8DlG58jAIJhX0GTr8dAKnr5Ew9xq8snHmPe9
vV6yO7edAgMBAAECggEAIzKOYC3l+7JjezU9G1pPah/vFhs/i+Lt9oQ4gmynd+TH
zZwFUghFjKu8YcoagHh8l923UT/eRZpy8kMjXbh0c/E58tK2ObbBA2QRvA/pTWFk
kPHwAHMA8KfI3TOlV/23v9OmKOj59XBbOgZlVl6+3lP1VlIHYAQVqj9XmVI7LMoZ
R30Hrhy0C9dJguqlFwgkiiRnM/3SAtpeqYqSYInfBaxiM4YdTOCOKlnTXmiY9a4U
GUvhof2H+OcY8JtADT26W7+FxXmzRnM8mGqQbiQu1PduJqOrG5eef2WSET6ikude
B7HvydtBp2LtCzfqg/5GwV93NcCbBzfwCunp9CvRIQKBgQDhM0xAZUU24MXiGN/k
nTD7NRoikLeLcnxGIAWt4c1f10bdTxeaJPZKeLqHuFu2y1IZkSVye30OyVyhVlZM
EzMiLRPwAWt9Pg5zGTp7MU0y5jQWBNU2Dw6wVtNUTpZgd1nzrc2pRjZffdSVnuHD
QJ47n69NHjrASWBiTCfPDM4b2QKBgQDUPVINDGW3vhtoPU47r4cM9XVvP1RTaoeV
0UT0ukETm/Q9ouVFmcJDoOsyyMOkUgSbZ4gJ3QgBbrDp7y1jZ9vGpeZWAJfQhyi/
6LngldwZKvW97gGfpbEWGTWKpO/IhlunxRJCihNsnkwHsudxjdWaiu04b3iDVReC
N+EBtcKzZQKBgQDAX8HTgK8PohNogTdBY8Zj0Yjx3g3s4W+nt9MiJrH6HTw78USI
OOrr0xYEukgebrFDheonUbYS25B1gftWIVCc8UUG0S+xXUGasQJ0GjmIMX5tENPR
yisSGBmO+1MaNNpyfxYgdAoeqK7g4UiaMqj45gAqMJifig776XJYPOgUgQKBgFnI
hwlWEUGlflqedJXzLyJgRAmHtNiE3E6YdJ9Cm3z8IFpiqrLC1NdfH6AgJgNBXwmO
xpHFmzlf5h9QOtcufF6Ql9wR7CcexjJI9Tj4rF9JOSPbp3wtz7gVefzowTcG/4b9
azgSyRzN6kPnftkesxnpY2jYXxbPzF4d3WWnynGxAoGBAMogoBY3AZ8wWruR7A3I
Scf2C2aS8QMgz5JWkgoDnpC3NrpxA3uj7uUz847pzV3MkXzMrDm/UHAp2QoEMIkP
dHofjPtGL9tWBGy3QyWm0BxKvxipJMaBy/HHwjIQw9RqOS/JYqVJIhPMlJmRYsYX
KHpDM5nC0c2igQREhdC5dYsH
-----END PRIVATE KEY-----
"""

/// Runs a TLS handshake between two `EmbeddedChannel`s and returns the error, if any.
///
/// ## Why in-memory rather than a real socket
/// The first version of this test bound a real TLS server and connected to it. It worked, and it
/// hung the macOS CI job: real sockets need a `MultiThreadedEventLoopGroup`, its teardown needs
/// `syncShutdownGracefully()`, and every blocking step reachable from a swift-testing test costs
/// a cooperative-pool thread. On a core-constrained runner the pool starves and the whole run
/// stalls — 29 of 346 tests completed, then nothing, until the job timeout. It even defeats
/// `.timeLimit`, because a blocked thread cannot be cancelled.
///
/// `EmbeddedChannel` has no threads, no sockets and no event loop to shut down: it runs
/// everything inline on the calling thread. The handshake is real — same `NIOSSLClientHandler`
/// built by the same `makeTLSHandler` the connection bootstrap uses, same BoringSSL, same
/// version negotiation — only the transport is a byte pump instead of a socket.
private func handshakeError(
    clientFloor: MailTLSMinimumVersion,
    serverMaximum: TLSVersion
) throws -> Error? {
    let client = EmbeddedChannel()
    let server = EmbeddedChannel()
    defer {
        _ = try? client.finish()
        _ = try? server.finish()
    }

    let certificate = try NIOSSLCertificate(bytes: Array(testCertPEM.utf8), format: .pem)
    let privateKey = try NIOSSLPrivateKey(bytes: Array(testKeyPEM.utf8), format: .pem)

    var serverConfiguration = TLSConfiguration.makeServerConfiguration(
        certificateChain: [.certificate(certificate)],
        privateKey: .privateKey(privateKey)
    )
    // The peer under test: it cannot go above this version.
    serverConfiguration.maximumTLSVersion = serverMaximum
    let serverContext = try NIOSSLContext(configuration: serverConfiguration)
    try server.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: serverContext))

    // The client handler comes from the same factory the real bootstrap calls, with the same
    // arguments — this is the code path the reported defect lived in.
    let clientHandler = try IMAPConnection.makeTLSHandler(
        for: client,
        host: "localhost",
        certificateVerificationPolicy: .noVerification,
        minimumTLSVersion: clientFloor
    )
    try client.pipeline.syncOperations.addHandler(clientHandler)

    try client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 993)).wait()
    try server.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 993)).wait()

    // Pump bytes between the two until neither has anything left to say. Any handshake failure
    // surfaces as a throw from `writeInbound`.
    do {
        var moved = true
        while moved {
            moved = false
            if let outbound = try client.readOutbound(as: ByteBuffer.self) {
                moved = true
                try server.writeInbound(outbound)
            }
            if let outbound = try server.readOutbound(as: ByteBuffer.self) {
                moved = true
                try client.writeInbound(outbound)
            }
        }
        return nil
    } catch {
        return error
    }
}

/// Is the configured TLS floor actually enforced during the handshake?
///
/// ## What these cover that `MailTLSConfigurationTests` cannot
/// That suite asserts `makeClientConfiguration(minimumTLSVersion: .tlsv13)` returns `.tlsv13` —
/// and it always did. One of its cases was even named *"Raising the floor to TLS 1.3 makes a
/// downgrade impossible"*, while a downgrade on port 993 was entirely possible: the implicit-TLS
/// call site never passed the value. That test could not have failed, because it verified that a
/// factory returns what it is handed, and the defect was that nobody handed it the value.
///
/// These run a real handshake against a peer pinned below the floor, through the same
/// `makeTLSHandler` the bootstrap uses. Verified by reverting the fix: the first one fails.
///
/// ## What they do *not* cover — stated plainly, because the last omission cost a release
/// They prove the floor is **enforced** once it reaches the handler. They do **not** prove the
/// call sites **pass** it — which is precisely what the reported defect was. Calling
/// `makeTLSHandler` directly, as these do, hands it the value the bootstrap forgot.
///
/// That gap is closed by the compiler rather than by a test: `makeTLSHandler` and
/// `IMAPConnection`'s designated initializer no longer default `minimumTLSVersion`, so a call
/// site that omits it does not build. A guarantee the compiler enforces is worth more than one a
/// test checks — but it is a different guarantee, and pretending otherwise here would repeat the
/// mistake this file exists to document. ``IMAPSecurityPolicyPropagationTests`` additionally
/// asserts that spawned connections carry the configured value.
@Suite("TLS floor is enforced during the handshake", .timeLimit(.minutes(1)))
struct IMAPTLSFloorEnforcementTests {

    /// The regression test for the reported defect.
    @Test("A TLS 1.3 floor refuses a peer that stops at TLS 1.2")
    func tls13FloorRefusesTLS12Peer() throws {
        let error = try handshakeError(clientFloor: .tlsv13, serverMaximum: .tlsv12)
        #expect(error != nil, "A TLS 1.2 peer must not be accepted when the floor is TLS 1.3")
    }

    /// The control. Without it the test above proves only "the handshake fails", which it would
    /// also do for a bad certificate, a broken pump, or a misconfigured server.
    @Test("The same peer is accepted when the floor is TLS 1.2")
    func tls12FloorAcceptsTLS12Peer() throws {
        let error = try handshakeError(clientFloor: .tlsv12, serverMaximum: .tlsv12)
        #expect(error == nil, "Expected a clean handshake, got: \(String(describing: error))")
    }

    /// The floor is a floor, not an exact match: a peer that can go higher is fine.
    @Test("A TLS 1.2 floor still negotiates TLS 1.3 with a capable peer")
    func tls12FloorAcceptsTLS13Peer() throws {
        let error = try handshakeError(clientFloor: .tlsv12, serverMaximum: .tlsv13)
        #expect(error == nil, "Expected a clean handshake, got: \(String(describing: error))")
    }
}
