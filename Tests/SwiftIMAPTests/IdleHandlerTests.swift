import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IdleHandlerTests {
    @Test
    func testIdleStartedKeepsHandlerActiveUntilTaggedOK() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        var continuationRef: AsyncStream<IMAPServerEvent>.Continuation?
        _ = AsyncStream<IMAPServerEvent> { continuation in
            continuationRef = continuation
        }

        guard let continuation = continuationRef else {
            Issue.record("Failed to create IDLE test stream continuation")
            return
        }

        let promise = channel.eventLoop.makePromise(of: Void.self)
        let handler = IdleHandler(commandTag: "A001", promise: promise, continuation: continuation)
        try await channel.pipeline.addHandler(handler)

        let idleStart = TaggedCommand(tag: "A001", command: .idleStart)
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(idleStart)))

        guard var idleCommandLine = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound IDLE command")
            return
        }
        #expect(idleCommandLine.readString(length: idleCommandLine.readableBytes) == "A001 IDLE\r\n")

        var idleConfirmation = channel.allocator.buffer(capacity: 0)
        idleConfirmation.writeString("+ idling\r\n")
        try await channel.writeInbound(idleConfirmation)

        #expect(!handler.isCompleted)
        #expect(handler.hasEnteredIdleState)

        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.idleDone))

        guard var doneLine = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound DONE command")
            return
        }
        #expect(doneLine.readString(length: doneLine.readableBytes) == "DONE\r\n")

        var taggedOK = channel.allocator.buffer(capacity: 0)
        taggedOK.writeString("A001 OK Idle terminated\r\n")
        try await channel.writeInbound(taggedOK)

        try await promise.futureResult.get()
        #expect(handler.isCompleted)
    }

    @Test
    func testByeDuringIdleCompletesWithoutDoneOrTaggedOK() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        var continuationRef: AsyncStream<IMAPServerEvent>.Continuation?
        let stream = AsyncStream<IMAPServerEvent> { continuation in
            continuationRef = continuation
        }

        guard let continuation = continuationRef else {
            Issue.record("Failed to create IDLE test stream continuation")
            return
        }

        var iterator = stream.makeAsyncIterator()

        let promise = channel.eventLoop.makePromise(of: Void.self)
        let handler = IdleHandler(commandTag: "A001", promise: promise, continuation: continuation)
        try await channel.pipeline.addHandler(handler)

        let idleStart = TaggedCommand(tag: "A001", command: .idleStart)
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(idleStart)))

        guard var idleCommandLine = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound IDLE command")
            return
        }
        #expect(idleCommandLine.readString(length: idleCommandLine.readableBytes) == "A001 IDLE\r\n")

        var idleConfirmation = channel.allocator.buffer(capacity: 0)
        idleConfirmation.writeString("+ idling\r\n")
        try await channel.writeInbound(idleConfirmation)

        var byeLine = channel.allocator.buffer(capacity: 0)
        byeLine.writeString("* BYE Disconnected for inactivity.\r\n")
        try await channel.writeInbound(byeLine)

        try await promise.futureResult.get()
        #expect(handler.isCompleted)

        let firstEvent = await iterator.next()
        if case .some(.bye(let text)) = firstEvent {
            #expect(text == "Disconnected for inactivity.")
        } else {
            Issue.record("Expected BYE event during IDLE")
        }

        let secondEvent = await iterator.next()
        #expect(secondEvent == nil)
        let outboundAfterBye = try await channel.readOutbound(as: ByteBuffer.self)
        if case .some = outboundAfterBye {
            Issue.record("Did not expect outbound data after BYE")
        }
    }
}
