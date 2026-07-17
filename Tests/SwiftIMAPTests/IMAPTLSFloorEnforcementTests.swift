import Testing
import Foundation
import NIO
import NIOSSL
@testable import SwiftMail

/// Does the configured TLS floor actually reach the socket?
///
/// ## Why these tests speak to a real server instead of inspecting a `TLSConfiguration`
/// Because the bug this file exists for was invisible at that level. `MailTLSConfigurationTests`
/// asserts that `makeClientConfiguration(minimumTLSVersion: .tlsv1_3)` returns `.tlsv13` — and it
/// always did. One of those tests is even called *"Raising the floor to TLS 1.3 makes a downgrade
/// impossible"*. Meanwhile the implicit-TLS call site never passed the value, so on port 993 —
/// the port every IMAPS client uses — the floor stayed at TLS 1.2 and a downgrade was entirely
/// possible. The test could not have failed: it verified that a factory returns what it is given,
/// while the defect was that nobody handed it the value.
///
/// A test that cannot produce the failure proves nothing about it. So these connect a real
/// `IMAPConnection` to a real TLS endpoint that refuses to speak anything above TLS 1.2, and
/// assert on the outcome. Delete the `minimumTLSVersion:` argument at any call site and one of
/// them goes red.
@Suite("TLS floor is honored on the wire")
struct IMAPTLSFloorEnforcementTests {

    // Self-signed, CN=localhost, generated for this test only and valid for 100 years so it
    // cannot rot. The client uses `.noVerification`, so trust is not what is under test here —
    // only the negotiated protocol version is.
    static let certPEM = """
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

    static let keyPEM = """
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

    /// A TLS endpoint that will not negotiate above TLS 1.2, and greets like an IMAP server.
    ///
    /// This is the piece that makes the failure reproducible: a real downgraded peer. Without it
    /// there is nothing for a TLS 1.3 floor to refuse.
    private final class TLS12OnlyServer {
        let channel: Channel
        let group: EventLoopGroup

        var port: Int { channel.localAddress?.port ?? 0 }

        init() throws {
            group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

            let cert = try NIOSSLCertificate(bytes: Array(certPEM.utf8), format: .pem)
            let key = try NIOSSLPrivateKey(bytes: Array(keyPEM.utf8), format: .pem)

            var configuration = TLSConfiguration.makeServerConfiguration(
                certificateChain: [.certificate(cert)],
                privateKey: .privateKey(key)
            )
            // The whole point: this peer cannot go above 1.2.
            configuration.minimumTLSVersion = .tlsv12
            configuration.maximumTLSVersion = .tlsv12

            let context = try NIOSSLContext(configuration: configuration)

            channel = try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    do {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                        try channel.pipeline.syncOperations.addHandler(GreetingSender())
                        return channel.eventLoop.makeSucceededFuture(())
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        }

        func shutdown() {
            try? channel.close().wait()
            try? group.syncShutdownGracefully()
        }

        /// Sends an IMAP greeting once TLS is up, so a successful handshake is observable.
        private final class GreetingSender: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            func channelActive(context: ChannelHandlerContext) {
                var buffer = context.channel.allocator.buffer(capacity: 64)
                buffer.writeString("* OK [CAPABILITY IMAP4rev1] Test server ready\r\n")
                context.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)
            }
        }
    }

    private func makeConnection(
        port: Int,
        minimumTLSVersion: MailTLSMinimumVersion,
        group: EventLoopGroup
    ) -> IMAPConnection {
        IMAPConnection(
            host: "localhost",
            port: port,
            transportSecurity: .implicitTLS,
            // Not what is under test — the certificate is self-signed on purpose.
            certificateVerificationPolicy: .noVerification,
            minimumTLSVersion: minimumTLSVersion,
            group: group,
            loggerLabel: "test",
            outboundLabel: "test.out",
            inboundLabel: "test.in",
            connectionID: "test",
            connectionRole: "test",
            parserLimits: .default
        )
    }

    /// 🔴 The regression test for the reported defect: implicit TLS on port 993 ignored the floor.
    @Test("Implicit TLS refuses a TLS 1.2 peer when the floor is TLS 1.3")
    func implicitTLSHonorsFloor() async throws {
        let server = try TLS12OnlyServer()
        defer { server.shutdown() }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let connection = makeConnection(port: server.port, minimumTLSVersion: .tlsv1_3, group: group)
        await #expect(throws: Error.self) {
            try await connection.connect()
        }
        try? await connection.disconnect()
    }

    /// The control. Without it the test above proves only "connecting fails", which it would
    /// also do if the port were closed, the certificate rejected, or the greeting malformed.
    @Test("The same peer connects when the floor is TLS 1.2")
    func tls12FloorConnects() async throws {
        let server = try TLS12OnlyServer()
        defer { server.shutdown() }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let connection = makeConnection(port: server.port, minimumTLSVersion: .tlsv1_2, group: group)
        try await connection.connect()
        try? await connection.disconnect()
    }
}
