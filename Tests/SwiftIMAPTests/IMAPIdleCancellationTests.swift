import NIO
import NIOEmbedded
import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPIdleCancellationTests {
    @Test
    func cancelledDoneRecyclesChannelBeforeDroppingIdleState() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            Task {
                try? await group.shutdownGracefully()
            }
        }

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

        _ = try await connection.idle()
        guard var idleCommandLine = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound IDLE command")
            return
        }
        #expect(idleCommandLine.readString(length: idleCommandLine.readableBytes) == "A001 IDLE\r\n")

        var idleConfirmation = channel.allocator.buffer(capacity: 0)
        idleConfirmation.writeString("+ idling\r\n")
        try await channel.writeInbound(idleConfirmation)

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

        let doneTask = Task {
            try await connection.done(timeoutSeconds: 1)
        }
        doneTask.cancel()
        blockerRelease.continuation.yield(())
        blockerRelease.continuation.finish()
        await blocker.value

        do {
            try await doneTask.value
            Issue.record("Expected cancelled DONE to throw CancellationError")
        } catch is CancellationError {
            // Expected. The connection must still be recycled before this leaves.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(connection.channel == nil)
        #expect(connection.idleHandler == nil)
        #expect(!connection.responseBuffer.hasActiveHandler)
    }
}
