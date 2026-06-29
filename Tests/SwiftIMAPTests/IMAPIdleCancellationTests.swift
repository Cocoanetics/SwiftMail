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
