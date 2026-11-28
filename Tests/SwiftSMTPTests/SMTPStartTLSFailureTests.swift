import Foundation
import NIO
import NIOEmbedded
import NIOSSL
import NIOTLS
import Testing
@testable import SwiftMail

/// What a failed STARTTLS upgrade reports. The end-to-end cases run against a
/// scripted server that offers STARTTLS and then answers it, or the client's
/// first TLS bytes, with something other than a completed handshake. That server
/// uses POSIX sockets, so those cases are gated like the other socket tests.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SMTPStartTLSFailureTests {
    private static let upgradeFailed = "STARTTLS upgrade failed: "

    private func tlsFailedReason(_ error: SMTPError?) -> String? {
        guard case .tlsFailed(let reason)? = error else {
            Issue.record("Expected tlsFailed, got \(String(describing: error))")
            return nil
        }
        return reason
    }

    #if os(macOS) || os(Linux)
    /// A fatal TLS alert record: content type 21, record version 3.1, length 2,
    /// level fatal (2), description protocol_version (70). A server that cannot
    /// speak the client's minimum TLS version answers its ClientHello with this.
    private static let protocolVersionAlert: [UInt8] = [0x15, 0x03, 0x01, 0x00, 0x02, 0x02, 0x46]

    /// Plain text where a TLS record should be.
    private static let notTLS: [UInt8] = Array("250 not a TLS record\r\n".utf8)

    private func connectError(
        answer: SMTPStartTLSAnswer,
        ehloCapabilities: [String] = ["STARTTLS"],
        connectionTimeouts: SMTPConnectionTimeouts = SMTPConnectionTimeouts()
    ) async throws -> (error: SMTPError?, commands: [String]) {
        var script = SMTPServerScript()
        script.startTLSAnswer = answer
        let testServer = SMTPTestServer(script: script, ehloCapabilities: ehloCapabilities)
        try testServer.start()
        var caught: SMTPError?
        try await testServer.run {
            let client = SMTPServer(
                host: "127.0.0.1",
                port: testServer.port,
                transportSecurity: .startTLS,
                connectionTimeouts: connectionTimeouts
            )
            do {
                try await client.connect()
                try? await client.disconnect()
            } catch let error as SMTPError {
                caught = error
            }
        }
        return (caught, testServer.recordedCommands)
    }

    // MARK: - The handshake's own error is reported

    @Test
    func handshakeRefusedWithProtocolVersionAlertReportsTheTLSReason() async throws {
        let result = try await connectError(answer: .acceptThenAnswerHandshake(Self.protocolVersionAlert))
        let reason = try #require(tlsFailedReason(result.error))
        #expect(reason.hasPrefix(Self.upgradeFailed), "\(reason)")
        #expect(reason.contains("TLSV1_ALERT_PROTOCOL_VERSION"), "\(reason)")
        #expect(!reason.contains("Command failed"), "\(reason)")
        #expect(result.commands.contains("STARTTLS"), "\(result.commands)")
    }

    @Test
    func handshakeAnsweredWithPlainTextReportsTheTLSError() async throws {
        let result = try await connectError(answer: .acceptThenAnswerHandshake(Self.notTLS))
        let reason = try #require(tlsFailedReason(result.error))
        #expect(reason.hasPrefix(Self.upgradeFailed + "handshakeFailed("), "\(reason)")
        #expect(reason.contains("WRONG_VERSION_NUMBER"), "\(reason)")
    }

    @Test
    func handshakeEndedByTheServerReportsTheTLSError() async throws {
        // The server reads the ClientHello, answers nothing and hangs up.
        let result = try await connectError(answer: .acceptThenAnswerHandshake([]))
        let reason = try #require(tlsFailedReason(result.error))
        #expect(reason.hasPrefix(Self.upgradeFailed + "handshakeFailed("), "\(reason)")
        #expect(reason.contains("EOF"), "\(reason)")
    }

    // MARK: - SMTP-level failures keep their own text

    @Test
    func refusedSTARTTLSReportsTheServerReply() async throws {
        let result = try await connectError(answer: .refuse("454 4.7.0 TLS not available due to temporary reason"))
        let reason = try #require(tlsFailedReason(result.error))
        #expect(reason == Self.upgradeFailed
            + "SMTP TLS failed: STARTTLS failed: 454 4.7.0 TLS not available due to temporary reason")
    }

    @Test
    func unansweredSTARTTLSReportsTheTimeout() async throws {
        let result = try await connectError(
            answer: .silence,
            connectionTimeouts: SMTPConnectionTimeouts(startTLSResponse: 0.2)
        )
        let reason = try #require(tlsFailedReason(result.error))
        #expect(reason == Self.upgradeFailed + "SMTP connection failed: STARTTLS timeout")
    }

    @Test
    func lowercaseSTARTTLSKeywordIsUpgraded() async throws {
        let result = try await connectError(
            answer: .refuse("454 4.7.0 TLS not available due to temporary reason"),
            ehloCapabilities: ["starttls"]
        )
        #expect(result.commands.contains("STARTTLS"), "\(result.commands)")
        let reason = try #require(tlsFailedReason(result.error))
        #expect(reason.contains("454"), "\(reason)")
    }
    #endif

    // MARK: - Before the handshake, a closed connection is a connection failure

    @Test
    func connectionClosedBeforeTheHandshakeIsAConnectionFailure() async throws {
        let server = SMTPServer(host: "smtp.example.com", port: 587, transportSecurity: .startTLS)
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 587))
        await server.replaceChannelForTesting(channel)

        let outcome = Task { () -> Error? in
            do {
                try await server.applyPostEHLOTLSPolicy(
                    transportMode: .startTLSRequired,
                    capabilities: ["STARTTLS"]
                )
                return nil
            } catch {
                return error
            }
        }

        // The server accepts STARTTLS and closes the connection in the same turn of
        // the event loop, so the TLS handler can only be added to a closed channel.
        _ = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
        try await channel.testingEventLoop.executeInContext {
            let accepted = SMTPResponse(code: 220, message: "2.0.0 Ready to start TLS")
            channel.pipeline.syncOperations.fireChannelRead(NIOAny(accepted))
            channel.close(promise: nil)
        }

        let reason = try #require(tlsFailedReason(await outcome.value as? SMTPError))
        #expect(reason == Self.upgradeFailed
            + "SMTP connection failed: Connection closed before the TLS handshake started")
        #expect(await !server.hasChannelForTesting)
    }

    // MARK: - During the handshake, the first error is the one reported

    /// A socket error is the connection failing, whatever its words: a reset, a
    /// read that timed out, and a network that went down all read as one.
    @Test(arguments: [ECONNRESET, ETIMEDOUT, ENETDOWN])
    func socketErrorDuringTheHandshakeIsAConnectionFailureReportedOverTheLaterEOF(
        errnoCode: CInt
    ) async throws {
        let server = SMTPServer(host: "smtp.example.com", port: 587, transportSecurity: .startTLS)
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 587))
        await server.replaceChannelForTesting(channel)

        let outcome = Task { () -> Error? in
            do {
                try await server.applyPostEHLOTLSPolicy(
                    transportMode: .startTLSRequired,
                    capabilities: ["STARTTLS"]
                )
                return nil
            } catch {
                return error
            }
        }

        // STARTTLS is accepted, so the real TLS handler goes in and sends its ClientHello.
        _ = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
        try await channel.writeInbound(SMTPResponse(code: 220, message: "2.0.0 Ready to start TLS"))
        _ = try await channel.waitForOutboundWrite(as: ByteBuffer.self)

        // What a socket channel does when a read fails mid-handshake: it reports the
        // error, then goes inactive on its own (not through the TLS handler's close), so
        // the TLS handler reports end of stream during the handshake as a second error.
        let socketError = IOError(errnoCode: errnoCode, reason: "read(descriptor:pointer:size:)")
        try await channel.testingEventLoop.executeInContext {
            channel.pipeline.fireErrorCaught(socketError)
            channel.pipeline.fireChannelInactive()
        }

        let reason = try #require(tlsFailedReason(await outcome.value as? SMTPError))
        #expect(reason == Self.upgradeFailed + "SMTP connection failed: \(socketError)")
        #expect(await !server.hasChannelForTesting)
    }

    @Test
    func socketErrorBeforeTheHandshakeIsAConnectionFailure() async throws {
        let server = SMTPServer(host: "smtp.example.com", port: 587, transportSecurity: .startTLS)
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 587))
        await server.replaceChannelForTesting(channel)

        let socketError = IOError(errnoCode: ETIMEDOUT, reason: "write(descriptor:pointer:size:)")
        var caught: SMTPError?
        do {
            try await server.applyPostEHLOTLSPolicy(
                transportMode: .startTLSRequired,
                capabilities: ["STARTTLS"],
                startTLSOverrideForTesting: { throw socketError }
            )
        } catch let error as SMTPError {
            caught = error
        }

        let reason = try #require(tlsFailedReason(caught))
        #expect(reason == Self.upgradeFailed + "SMTP connection failed: \(socketError)")
        #expect(await !server.hasChannelForTesting)
    }

    // MARK: - After the handshake, the command's own error stands

    @Test
    func unansweredEHLOAfterUpgradeReportsTheTimeout() async throws {
        let server = SMTPServer(
            host: "smtp.example.com",
            port: 587,
            transportSecurity: .startTLS,
            connectionTimeouts: SMTPConnectionTimeouts(ehloResponse: 0.2)
        )
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 587))
        await server.replaceChannelForTesting(channel)

        var caught: SMTPError?
        do {
            // The TLS bytes are skipped; the EHLO that follows the upgrade is never answered.
            try await server.applyPostEHLOTLSPolicy(
                transportMode: .startTLSRequired,
                capabilities: ["STARTTLS"],
                startTLSOverrideForTesting: { nil }
            )
        } catch let error as SMTPError {
            caught = error
        }
        let reason = try #require(tlsFailedReason(caught))
        #expect(reason == Self.upgradeFailed + "SMTP connection failed: EHLO timeout")
        #expect(await !server.hasChannelForTesting)
    }

    @Test
    func errorAfterCompletedHandshakeLeavesTheEHLOReplyAsTheResult() async throws {
        let server = SMTPServer(host: "smtp.example.com", port: 587, transportSecurity: .startTLS)
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 587))
        await server.replaceChannelForTesting(channel)

        let outcome = Task { () -> Error? in
            do {
                try await server.applyPostEHLOTLSPolicy(
                    transportMode: .startTLSRequired,
                    capabilities: ["STARTTLS"],
                    startTLSOverrideForTesting: {
                        // Stands in for the TLS handler: the handshake completes,
                        // then a TLS error arrives, as when a server closes the
                        // connection without a TLS close notification.
                        let recorder = TLSHandshakeErrorRecorder(eventLoop: channel.eventLoop)
                        try await channel.eventLoop.submit {
                            try channel.pipeline.syncOperations.addHandler(recorder, position: .first)
                            channel.pipeline.fireUserInboundEventTriggered(
                                TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil)
                            )
                            channel.pipeline.fireErrorCaught(NIOSSLError.uncleanShutdown)
                        }.get()
                        // The error went on down the pipeline.
                        await #expect(throws: NIOSSLError.self) { try await channel.throwIfErrorCaught() }
                        return recorder
                    }
                )
                return nil
            } catch {
                return error
            }
        }

        // The server's reply to the EHLO passes through the recorder to the command.
        _ = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
        try await channel.writeInbound(SMTPResponse(code: 421, message: "4.3.2 Service not available"))

        let reason = try #require(tlsFailedReason(await outcome.value as? SMTPError))
        #expect(reason.hasPrefix(Self.upgradeFailed + "SMTP "), "\(reason)")
        #expect(reason == Self.upgradeFailed + "SMTP connection failed: SMTP error: 421 4.3.2 Service not available")
        #expect(await !server.hasChannelForTesting)
    }

    // MARK: - EHLO keywords in any case

    @Test
    func ehloKeywordsAreReadInAnyCase() async {
        let server = SMTPServer(host: "smtp.example.com", port: 587)
        let capabilities = await server.parseCapabilities(
            from: "250-smtp.test greets you\n250-starttls\n250-8bitmime\n250-Size 1000\n250-xprofile AbCd\n"
                + "250 auth plain login"
        )
        #expect(capabilities.contains("STARTTLS"), "\(capabilities)")
        #expect(capabilities.contains("8BITMIME"), "\(capabilities)")
        #expect(capabilities.contains("AUTH"), "\(capabilities)")
        #expect(capabilities.contains("AUTH PLAIN"), "\(capabilities)")
        #expect(capabilities.contains("AUTH LOGIN"), "\(capabilities)")
        #expect(SMTPServer.maximumMessageSizeOctets(from: capabilities) == 1000)
        // Only the keyword is normalized; a parameter keeps the server's spelling.
        #expect(capabilities.contains("XPROFILE AbCd"), "\(capabilities)")
    }
}
