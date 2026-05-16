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
struct XOAUTH2AuthenticationHandlerFailureTests {
    @Test
    func serverErrorBlobTriggersAuthFailure() async throws {
        let setup = try await Fixtures.setUpChannel(tag: "A003", expectsChallenge: false)
        let channel = setup.channel
        let promise = setup.promise

        let command = TaggedCommand(
            tag: "A003",
            command: .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: InitialResponse(Fixtures.makeCredentialBuffer(using: channel.allocator))
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
                case let .authFailed(message):
                    #expect(message.contains("AUTHENTICATE failed"))
                default:
                    Issue.record("Unexpected IMAPError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func directNOFailsAuthentication() async throws {
        let setup = try await Fixtures.setUpChannel(tag: "A004", expectsChallenge: false)
        let channel = setup.channel
        let promise = setup.promise

        let command = TaggedCommand(
            tag: "A004",
            command: .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: InitialResponse(Fixtures.makeCredentialBuffer(using: channel.allocator))
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
    func channelCloseFailsPendingAuthentication() async throws {
        let setup = try await Fixtures.setUpChannel(tag: "A005", expectsChallenge: false)
        let channel = setup.channel
        let promise = setup.promise

        let command = TaggedCommand(
            tag: "A005",
            command: .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: InitialResponse(Fixtures.makeCredentialBuffer(using: channel.allocator))
            )
        )

        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        try await channel.close().get()

        do {
            _ = try await promise.futureResult.get()
            Issue.record("Expected connection failure when channel closes")
        } catch let error as IMAPError {
            if case let .connectionFailed(message) = error {
                #expect(message.contains("Connection closed before command completed"))
            } else {
                Issue.record("Unexpected IMAPError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func inactiveChannelDuringContinuationSendFailsPromptly() async throws {
        let setup = try await Fixtures.setUpChannel(
            tag: "A006",
            expectsChallenge: true,
            failContinuationWrite: true
        )
        let channel = setup.channel
        let promise = setup.promise

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
            _ = try await Fixtures.withTimeout(seconds: 1.0) {
                try await promise.futureResult.get()
            }
            Issue.record("Expected continuation send failure")
        } catch is XOAUTH2TimeoutError {
            Issue.record("Authentication promise timed out (possible hang / leaked promise)")
        } catch {
            // expected immediate failure path
        }
    }
}
