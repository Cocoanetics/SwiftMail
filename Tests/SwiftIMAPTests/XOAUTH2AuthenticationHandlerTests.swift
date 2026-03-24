import Foundation
import Logging
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

private struct TimeoutError: Error {}

private final class FailContinuationWriteHandler: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = IMAPClientHandler.OutboundIn

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let outbound = unwrapOutboundIn(data)
        if case .part(.continuationResponse) = outbound {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }

        context.write(data, promise: promise)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct XOAUTH2AuthenticationHandlerTests {
    private let email = "user@example.com"
    private let token = "ya29.A0AfH6SExample"
    private let logger: Logger = {
        var logger = Logger(label: "com.swiftmail.tests.xoauth2")
        logger.logLevel = .critical
        return logger
    }()

    @Test
    func testSASLIRSuccess() async throws {
        let (channel, promise, _) = try await setUpChannel(tag: "A001", expectsChallenge: false)

        let command = TaggedCommand(
            tag: "A001",
            command: .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: InitialResponse(makeCredentialBuffer(using: channel.allocator))
            )
        )

        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected AUTHENTICATE command")
            return
        }
        let commandString = outbound.readString(length: outbound.readableBytes)
        let expectedBase64 = makeBase64String()
        #expect(commandString == "A001 AUTHENTICATE XOAUTH2 \(expectedBase64)\r\n")

        var okBuffer = channel.allocator.buffer(capacity: 0)
        okBuffer.writeString("A001 OK AUTHENTICATE completed\r\n")
        try await channel.writeInbound(okBuffer)

        let capabilities = try await promise.futureResult.get()
        #expect(capabilities.isEmpty)
    }

    @Test
    func testFallbackWithoutSASLIR() async throws {
        let (channel, promise, _) = try await setUpChannel(tag: "A002", expectsChallenge: true)

        let command = TaggedCommand(
            tag: "A002",
            command: .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: nil
            )
        )

        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))

        guard var firstOutbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected AUTHENTICATE command")
            return
        }
        let firstLine = firstOutbound.readString(length: firstOutbound.readableBytes)
        #expect(firstLine == "A002 AUTHENTICATE XOAUTH2\r\n")

        var challengeBuffer = channel.allocator.buffer(capacity: 0)
        challengeBuffer.writeString("+ \r\n")
        try await channel.writeInbound(challengeBuffer)

        guard var continuation = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected XOAUTH2 continuation data")
            return
        }
        let continuationLine = continuation.readString(length: continuation.readableBytes)
        let expectedBase64 = makeBase64String()
        #expect(continuationLine == "\(expectedBase64)\r\n")

        var okBuffer = channel.allocator.buffer(capacity: 0)
        okBuffer.writeString("A002 OK AUTHENTICATE completed\r\n")
        try await channel.writeInbound(okBuffer)

        let capabilities = try await promise.futureResult.get()
        #expect(capabilities.isEmpty)
    }


    @Test
    func testSASLIRServerSendsEmptyChallengeRetriesCredentials() async throws {
        let (channel, promise, _) = try await setUpChannel(tag: "A002A", expectsChallenge: false)

        let command = TaggedCommand(
            tag: "A002A",
            command: .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: InitialResponse(makeCredentialBuffer(using: channel.allocator))
            )
        )

        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))

        guard var firstOutbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected AUTHENTICATE command")
            return
        }
        let firstLine = firstOutbound.readString(length: firstOutbound.readableBytes)
        let expectedBase64 = makeBase64String()
        #expect(firstLine == "A002A AUTHENTICATE XOAUTH2 \(expectedBase64)\r\n")

        var challengeBuffer = channel.allocator.buffer(capacity: 0)
        challengeBuffer.writeString("+ \r\n")
        try await channel.writeInbound(challengeBuffer)

        guard var continuation = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected XOAUTH2 continuation retry data")
            return
        }
        let continuationLine = continuation.readString(length: continuation.readableBytes)
        #expect(continuationLine == "\(expectedBase64)\r\n")

        var okBuffer = channel.allocator.buffer(capacity: 0)
        okBuffer.writeString("A002A OK AUTHENTICATE completed\r\n")
        try await channel.writeInbound(okBuffer)

        let capabilities = try await promise.futureResult.get()
        #expect(capabilities.isEmpty)
    }

    @Test
    func testServerErrorBlobTriggersAuthFailure() async throws {
        let (channel, promise, _) = try await setUpChannel(tag: "A003", expectsChallenge: false)

        let command = TaggedCommand(
            tag: "A003",
            command: .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: InitialResponse(makeCredentialBuffer(using: channel.allocator))
            )
        )

        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))

        _ = try await channel.readOutbound(as: ByteBuffer.self) // discard AUTH line

        var challengeBuffer = channel.allocator.buffer(capacity: 0)
        challengeBuffer.writeString("+ eyJzdGF0dXMiOiI0MDEiLCJtZXNzYWdlIjoiSW52YWxpZCB0b2tlbiJ9\r\n")
        try await channel.writeInbound(challengeBuffer)

        guard var responseBuffer = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected empty continuation response")
            return
        }
        let responseLine = responseBuffer.readString(length: responseBuffer.readableBytes)
        #expect(responseLine == "\r\n")

        var noBuffer = channel.allocator.buffer(capacity: 0)
        noBuffer.writeString("A003 NO AUTHENTICATE failed\r\n")
        try await channel.writeInbound(noBuffer)

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

        let command = TaggedCommand(
            tag: "A004",
            command: .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: InitialResponse(makeCredentialBuffer(using: channel.allocator))
            )
        )

        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        var noBuffer = channel.allocator.buffer(capacity: 0)
        noBuffer.writeString("A004 NO AUTHENTICATE failed\r\n")
        try await channel.writeInbound(noBuffer)

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


    @Test
    func testChannelCloseFailsPendingAuthentication() async throws {
        let (channel, promise, _) = try await setUpChannel(tag: "A005", expectsChallenge: false)

        let command = TaggedCommand(
            tag: "A005",
            command: .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: InitialResponse(makeCredentialBuffer(using: channel.allocator))
            )
        )

        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        try await channel.close().get()

        do {
            _ = try await promise.futureResult.get()
            Issue.record("Expected connection failure when channel closes")
        } catch let error as IMAPError {
            if case .connectionFailed(let message) = error {
                #expect(message.contains("Connection closed before command completed"))
            } else {
                Issue.record("Unexpected IMAPError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func testInactiveChannelDuringContinuationSendFailsPromptly() async throws {
        let (channel, promise, _) = try await setUpChannel(tag: "A006", expectsChallenge: true, failContinuationWrite: true)

        let command = TaggedCommand(
            tag: "A006",
            command: .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: nil
            )
        )

        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        var challengeBuffer = channel.allocator.buffer(capacity: 0)
        challengeBuffer.writeString("+ \r\n")
        try await channel.writeInbound(challengeBuffer)

        do {
            _ = try await withTimeout(seconds: 1.0) {
                try await promise.futureResult.get()
            }
            Issue.record("Expected continuation send failure")
        } catch is TimeoutError {
            Issue.record("Authentication promise timed out (possible hang / leaked promise)")
        } catch {
            // expected immediate failure path
        }
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func setUpChannel(tag: String, expectsChallenge: Bool, failContinuationWrite: Bool = false) async throws -> (NIOAsyncTestingChannel, EventLoopPromise<[Capability]>, XOAUTH2AuthenticationHandler) {
        let channel = NIOAsyncTestingChannel()
        try await channel.pipeline.addHandler(IMAPClientHandler())

        if failContinuationWrite {
            try await channel.pipeline.addHandler(FailContinuationWriteHandler())
        }

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
