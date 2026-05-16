import Foundation
import Logging
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
@testable import SwiftMail
import Testing

private typealias Fixtures = XOAUTH2TestFixtures

@Suite(.serialized, .timeLimit(.minutes(1)))
struct XOAUTH2AuthenticationHandlerSuccessTests {
    @Test
    func sASLIRSuccess() async throws {
        let setup = try await Fixtures.setUpChannel(tag: "A001", expectsChallenge: false)
        let channel = setup.channel
        let promise = setup.promise

        let command = TaggedCommand(
            tag: "A001",
            command: .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: InitialResponse(Fixtures.makeCredentialBuffer(using: channel.allocator))
            )
        )

        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected AUTHENTICATE command")
            return
        }
        let commandString = outbound.readString(length: outbound.readableBytes)
        let expectedBase64 = Fixtures.makeBase64String()
        #expect(commandString == "A001 AUTHENTICATE XOAUTH2 \(expectedBase64)\r\n")

        var okBuffer = channel.allocator.buffer(capacity: 0)
        okBuffer.writeString("A001 OK AUTHENTICATE completed\r\n")
        try await channel.writeInbound(okBuffer)

        let capabilities = try await promise.futureResult.get()
        #expect(capabilities.isEmpty)
    }

    @Test
    func fallbackWithoutSASLIR() async throws {
        let setup = try await Fixtures.setUpChannel(tag: "A002", expectsChallenge: true)
        let channel = setup.channel
        let promise = setup.promise

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
        let expectedBase64 = Fixtures.makeBase64String()
        #expect(continuationLine == "\(expectedBase64)\r\n")

        var okBuffer = channel.allocator.buffer(capacity: 0)
        okBuffer.writeString("A002 OK AUTHENTICATE completed\r\n")
        try await channel.writeInbound(okBuffer)

        let capabilities = try await promise.futureResult.get()
        #expect(capabilities.isEmpty)
    }

    @Test
    func sASLIRServerSendsEmptyChallengeRetriesCredentials() async throws {
        let setup = try await Fixtures.setUpChannel(tag: "A002A", expectsChallenge: false)
        let channel = setup.channel
        let promise = setup.promise

        let command = TaggedCommand(
            tag: "A002A",
            command: .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: InitialResponse(Fixtures.makeCredentialBuffer(using: channel.allocator))
            )
        )

        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))

        guard var firstOutbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected AUTHENTICATE command")
            return
        }
        let firstLine = firstOutbound.readString(length: firstOutbound.readableBytes)
        let expectedBase64 = Fixtures.makeBase64String()
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
}
