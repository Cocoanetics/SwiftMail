import Foundation
import NIO
import NIOEmbedded
import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPIdleCancellationTests {
    private struct IdleHarness {
        let connection: IMAPConnection
        let channel: NIOAsyncTestingChannel
    }

    private struct CommandQueueBlocker {
        let task: Task<Void, Never>
        let release: AsyncStream<Void>.Continuation
    }

    @Test
    func cancelledDoneRecyclesChannelBeforeDroppingIdleState() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        do {
            let harness = try await makeIdleHarness(group: group)
            try await enterIdle(connection: harness.connection, channel: harness.channel)

            let blocker = await blockCommandQueue(on: harness.connection)
            let doneTask = Task {
                try await harness.connection.done(timeoutSeconds: 1)
            }
            doneTask.cancel()
            blocker.release.yield(())
            blocker.release.finish()
            await blocker.task.value

            do {
                try await doneTask.value
                Issue.record("Expected cancelled DONE to throw CancellationError")
            } catch is CancellationError {
                // Expected. The connection must still be recycled before this leaves.
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
            }

            #expect(harness.connection.channel == nil)
            #expect(harness.connection.idleHandler == nil)
            #expect(!harness.connection.responseBuffer.hasActiveHandler)

            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test
    func childTaskIdleStartWaitsForInFlightTaggedCommand() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        do {
            let harness = try await makeIdleHarness(group: group)
            let noopSent = AsyncStream<Void>.makeStream()
            let releaseNoop = AsyncStream<Void>.makeStream()
            let idleFinished = AsyncStream<Void>.makeStream()

            let outer = Task {
                try await harness.connection.commandQueue.run {
                    let pendingNoop = try await startNoopWithoutCompletion(harness: harness)
                    noopSent.continuation.yield(())
                    startIdleChild(harness: harness, idleFinished: idleFinished.continuation)

                    var releaseIterator = releaseNoop.stream.makeAsyncIterator()
                    await releaseIterator.next()
                    try await finishNoop(pendingNoop, harness: harness)
                }
            }

            var noopSentIterator = noopSent.stream.makeAsyncIterator()
            await noopSentIterator.next()
            try await assertNoopSentWithoutIdle(harness.channel)

            releaseNoop.continuation.yield(())
            releaseNoop.continuation.finish()
            try await outer.value

            var idleFinishedIterator = idleFinished.stream.makeAsyncIterator()
            await idleFinishedIterator.next()
            try await assertIdleStartedAndStop(harness: harness)

            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test
    func byeDuringDoneRecyclesChannelBeforeNextIdle() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        do {
            let harness = try await makeIdleHarness(group: group)
            try await enterIdle(connection: harness.connection, channel: harness.channel)

            let doneTask = Task {
                try await harness.connection.done(timeoutSeconds: 1)
            }

            guard let doneLine = try await nextOutboundLine(from: harness.channel) else {
                Issue.record("Expected outbound DONE command")
                try await group.shutdownGracefully()
                return
            }
            #expect(doneLine == "DONE\r\n")

            var bye = harness.channel.allocator.buffer(capacity: 0)
            bye.writeString("* BYE Server closing during IDLE termination\r\n")
            try await harness.channel.writeInbound(bye)

            do {
                try await doneTask.value
                Issue.record("Expected DONE to throw after BYE without tagged IDLE completion")
            } catch {
                // Expected: untagged BYE does not retire the active IDLE tag.
            }

            #expect(harness.connection.channel == nil)
            #expect(harness.connection.idleHandler == nil)
            #expect(!harness.connection.responseBuffer.hasActiveHandler)

            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private func makeIdleHarness(group: MultiThreadedEventLoopGroup) async throws -> IdleHarness {
        let connection = IMAPConnection(
            host: "localhost",
            port: 143,
            transportSecurity: .plainText,
            group: group,
            loggerLabel: "test.imap",
            outboundLabel: "test.imap.out",
            inboundLabel: "test.imap.in",
            connectionID: "test-idle-cancel",
            connectionRole: "test"
        )
        let channel = NIOAsyncTestingChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 143)
        try await channel.connect(to: address)
        try await channel.pipeline.addHandler(IMAPClientHandler())
        try await channel.pipeline.addHandler(connection.duplexLogger)
        try await channel.pipeline.addHandler(connection.responseBuffer)
        connection.replaceChannelForTesting(channel)
        connection.replaceCapabilitiesForTesting([.idle])

        return IdleHarness(connection: connection, channel: channel)
    }

    private struct PendingNoop {
        let tag: String
        let promise: EventLoopPromise<[IMAPServerEvent]>
    }

    private func startNoopWithoutCompletion(harness: IdleHarness) async throws -> PendingNoop {
        let tag = harness.connection.generateCommandTag()
        let promise = harness.channel.eventLoop.makePromise(of: [IMAPServerEvent].self)
        let handler = NoopHandler(commandTag: tag, promise: promise)
        try await harness.channel.pipeline.addHandler(
            handler,
            position: .before(harness.connection.responseBuffer)
        ).get()
        harness.connection.responseBuffer.hasActiveHandler = true
        try await NoopCommand().send(on: harness.channel, tag: tag)
        return PendingNoop(tag: tag, promise: promise)
    }

    private func finishNoop(_ pending: PendingNoop, harness: IdleHarness) async throws {
        var okLine = harness.channel.allocator.buffer(capacity: 0)
        okLine.writeString("\(pending.tag) OK NOOP completed\r\n")
        try await harness.channel.writeInbound(okLine)
        _ = try await pending.promise.futureResult.get()
        harness.connection.responseBuffer.hasActiveHandler = false
    }

    private func startIdleChild(
        harness: IdleHarness,
        idleFinished: AsyncStream<Void>.Continuation
    ) {
        Task {
            do {
                _ = try await harness.connection.idle()
            } catch {
                Issue.record("Expected child IDLE start to succeed after NOOP completed, got \(error)")
            }
            idleFinished.yield(())
            idleFinished.finish()
        }
    }

    private func assertNoopSentWithoutIdle(_ channel: NIOAsyncTestingChannel) async throws {
        guard let noopLine = try await nextOutboundLine(from: channel) else {
            Issue.record("Expected outbound NOOP command")
            return
        }
        #expect(noopLine == "A001 NOOP\r\n")

        try await Task.sleep(nanoseconds: 20_000_000)
        let prematureIdle = try await channel.readOutbound(as: ByteBuffer.self)
        #expect(prematureIdle == nil)
    }

    private func assertIdleStartedAndStop(harness: IdleHarness) async throws {
        guard let idleCommandLine = try await nextOutboundLine(from: harness.channel) else {
            Issue.record("Expected outbound IDLE command")
            return
        }
        #expect(idleCommandLine == "A002 IDLE\r\n")

        var idleConfirmation = harness.channel.allocator.buffer(capacity: 0)
        idleConfirmation.writeString("+ idling\r\n")
        try await harness.channel.writeInbound(idleConfirmation)
        try await stopIdle(connection: harness.connection, channel: harness.channel, tag: "A002")
    }

    private func enterIdle(connection: IMAPConnection, channel: NIOAsyncTestingChannel) async throws {
        _ = try await connection.idle()
        guard var idleCommandLine = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound IDLE command")
            return
        }
        #expect(idleCommandLine.readString(length: idleCommandLine.readableBytes) == "A001 IDLE\r\n")

        var idleConfirmation = channel.allocator.buffer(capacity: 0)
        idleConfirmation.writeString("+ idling\r\n")
        try await channel.writeInbound(idleConfirmation)
    }

    private func stopIdle(
        connection: IMAPConnection,
        channel: NIOAsyncTestingChannel,
        tag: String
    ) async throws {
        let doneTask = Task {
            try await connection.done(timeoutSeconds: 1)
        }

        guard let doneLine = try await nextOutboundLine(from: channel) else {
            Issue.record("Expected outbound DONE command")
            return
        }
        #expect(doneLine == "DONE\r\n")

        var taggedOK = channel.allocator.buffer(capacity: 0)
        taggedOK.writeString("\(tag) OK IDLE terminated\r\n")
        try await channel.writeInbound(taggedOK)
        try await doneTask.value
    }

    private func nextOutboundLine(
        from channel: NIOAsyncTestingChannel,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async throws -> String? {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if var line = try await channel.readOutbound(as: ByteBuffer.self) {
                return line.readString(length: line.readableBytes)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    private func blockCommandQueue(on connection: IMAPConnection) async -> CommandQueueBlocker {
        let blockerStarted = AsyncStream<Void>.makeStream()
        let blockerRelease = AsyncStream<Void>.makeStream()
        let blocker = Task {
            await connection.commandQueue.run {
                blockerStarted.continuation.yield(())
                for await _ in blockerRelease.stream {
                    break
                }
            }
        }

        var blockerIterator = blockerStarted.stream.makeAsyncIterator()
        await blockerIterator.next()

        return CommandQueueBlocker(task: blocker, release: blockerRelease.continuation)
    }
}
