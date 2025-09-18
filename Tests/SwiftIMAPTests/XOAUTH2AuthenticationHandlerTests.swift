import Foundation
import Logging
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

struct XOAUTH2AuthenticationHandlerTests {
    private let email = "user@example.com"
    private let token = "ya29.A0AfH6SExample"
    private let logger = Logger(label: "com.swiftmail.tests.xoauth2")

    @Test
    func testSASLIRSuccess() async throws {
        let (channel, promise, _) = try await setUpChannel(tag: "A001", expectsChallenge: false)
        defer { _ = try? channel.finish() }

        let command = TaggedCommand(
            tag: "A001",
            command: .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: InitialResponse(makeCredentialBuffer(using: channel.allocator))
            )
        )

        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))

        guard var outbound = try channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected AUTHENTICATE command")
            return
        }
        let commandString = outbound.readString(length: outbound.readableBytes)
        let expectedBase64 = makeBase64String()
        #expect(commandString == "A001 AUTHENTICATE XOAUTH2 \(expectedBase64)\r\n")

        var okBuffer = channel.allocator.buffer(capacity: 0)
        okBuffer.writeString("A001 OK AUTHENTICATE completed\r\n")
        try channel.writeInbound(okBuffer)

        let capabilities = try await promise.futureResult.get()
        #expect(capabilities.isEmpty)
    }

    @Test
    func testFallbackWithoutSASLIR() async throws {
        let (channel, promise, _) = try await setUpChannel(tag: "A002", expectsChallenge: true)
        defer { _ = try? channel.finish() }

        let command = TaggedCommand(
            tag: "A002",
            command: .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: nil
            )
        )

        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))

        guard var firstOutbound = try channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected AUTHENTICATE command")
            return
        }
        let firstLine = firstOutbound.readString(length: firstOutbound.readableBytes)
        #expect(firstLine == "A002 AUTHENTICATE XOAUTH2\r\n")

        var challengeBuffer = channel.allocator.buffer(capacity: 0)
        challengeBuffer.writeString("+ \r\n")
        try channel.writeInbound(challengeBuffer)

        guard var continuation = try channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected XOAUTH2 continuation data")
            return
        }
        let continuationLine = continuation.readString(length: continuation.readableBytes)
        let expectedBase64 = makeBase64String()
        #expect(continuationLine == "\(expectedBase64)\r\n")

        var okBuffer = channel.allocator.buffer(capacity: 0)
        okBuffer.writeString("A002 OK AUTHENTICATE completed\r\n")
        try channel.writeInbound(okBuffer)

        let capabilities = try await promise.futureResult.get()
        #expect(capabilities.isEmpty)
    }

    @Test
    func testServerErrorBlobTriggersAuthFailure() async throws {
        let (channel, promise, _) = try await setUpChannel(tag: "A003", expectsChallenge: false)
        defer { _ = try? channel.finish() }

        let command = TaggedCommand(
            tag: "A003",
            command: .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: InitialResponse(makeCredentialBuffer(using: channel.allocator))
            )
        )

        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))

        _ = try channel.readOutbound(as: ByteBuffer.self) // discard AUTH line

        var challengeBuffer = channel.allocator.buffer(capacity: 0)
        challengeBuffer.writeString("+ eyJzdGF0dXMiOiI0MDEiLCJtZXNzYWdlIjoiSW52YWxpZCB0b2tlbiJ9\r\n")
        try channel.writeInbound(challengeBuffer)

        guard var responseBuffer = try channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected empty continuation response")
            return
        }
        let responseLine = responseBuffer.readString(length: responseBuffer.readableBytes)
        #expect(responseLine == "\r\n")

        var noBuffer = channel.allocator.buffer(capacity: 0)
        noBuffer.writeString("A003 NO AUTHENTICATE failed\r\n")
        try channel.writeInbound(noBuffer)

        do {
            _ = try await promise.futureResult.get()
            Issue.record("Expected authentication failure")
        } catch let error as IMAPError {
            switch error {
            case .authFailed(let message):
                #expect(message.contains("AUTHENTICATE failed"))
            default:
                Issue.record("Unexpected IMAPError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func testDirectNOFailsAuthentication() async throws {
        let (channel, promise, _) = try await setUpChannel(tag: "A004", expectsChallenge: false)
        defer { _ = try? channel.finish() }

        let command = TaggedCommand(
            tag: "A004",
            command: .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: InitialResponse(makeCredentialBuffer(using: channel.allocator))
            )
        )

        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))
        _ = try channel.readOutbound(as: ByteBuffer.self)

        var noBuffer = channel.allocator.buffer(capacity: 0)
        noBuffer.writeString("A004 NO AUTHENTICATE failed\r\n")
        try channel.writeInbound(noBuffer)

        do {
            _ = try await promise.futureResult.get()
            Issue.record("Expected authentication failure")
        } catch let error as IMAPError {
            if case .authFailed = error {
                // expected path
            } else {
                Issue.record("Unexpected IMAPError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    private func setUpChannel(tag: String, expectsChallenge: Bool) async throws -> (EmbeddedChannel, EventLoopPromise<[Capability]>, XOAUTH2AuthenticationHandler) {
        let channel = EmbeddedChannel()
        try await channel.pipeline.addHandler(IMAPClientHandler())

        let promise = channel.eventLoop.makePromise(of: [Capability].self)
        let handler = XOAUTH2AuthenticationHandler(
            commandTag: tag,
            promise: promise,
            credentials: makeCredentialBuffer(using: channel.allocator),
            expectsChallenge: expectsChallenge,
            logger: logger
        )
        try await channel.pipeline.addHandler(handler)

        return (channel, promise, handler)
    }

    private func makeCredentialBuffer(using allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: email.utf8.count + token.utf8.count + 32)
        buffer.writeString("user=")
        buffer.writeString(email)
        buffer.writeInteger(UInt8(0x01))
        buffer.writeString("auth=Bearer ")
        buffer.writeString(token)
        buffer.writeInteger(UInt8(0x01))
        buffer.writeInteger(UInt8(0x01))
        return buffer
    }

    private func makeBase64String() -> String {
        let raw = "user=\(email)\u{01}auth=Bearer \(token)\u{01}\u{01}"
        return Data(raw.utf8).base64EncodedString()
    }
}
