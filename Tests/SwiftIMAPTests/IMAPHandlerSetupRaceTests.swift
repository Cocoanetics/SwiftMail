import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

extension IMAPBootstrapRaceTests {
    @Test(arguments: ["command", "handler", "PLAIN", "XOAUTH2", "IDLE"])
    func abortBetweenPromiseCreationAndBinding(path: String) async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let channel = try await installTransport(connection)
            connection.replaceCapabilitiesForTesting(connection.capabilitiesSnapshot.union([.idle]))
            let ownerFinished = IMAPTestSignal()
            connection.operationOwnerFinishedForTesting = ownerFinished.signal
            connection.handlerPromiseCreatedForTesting = { [weak connection] in connection?.abortNow() }
            defer { connection.abortNow() }

            await #expect(throws: IMAPAbortReason.connectionAborted) {
                try await connection.withOperation {
                    switch path {
                        case "command": _ = try await connection.executeCommandBody(NoopCommand())
                        case "handler":
                            let _: [IMAPServerEvent] = try await connection.executeHandlerOnly(
                                handlerType: NoopHandler.self)
                        case "PLAIN":
                            try await connection.authenticatePlainBody(username: "user", password: "secret")
                        case "XOAUTH2":
                            try await connection.authenticateXOAUTH2Body(
                                email: "user@example.com", accessToken: "token")
                        default:
                            let (_, continuation) = AsyncStream<IMAPServerEvent>.makeStream()
                            try await connection.startIdleSession(continuation: continuation)
                    }
                }
            }
            // Wait for the owner to release the handler promise, not just for
            // the caller's abort result. An unsettled promise traps on release.
            await ownerFinished.wait()
            try await channel.closeFuture.get()
            #expect(connection.channel == nil)
            #expect(try await channel.readOutbound(as: ByteBuffer.self) == nil)
        }
    }

    @Test
    func idleDoesNotReturnAStreamWhenItsPendingWriteFails() async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let channel = try await installTransport(connection)
            connection.replaceCapabilitiesForTesting([.idle])
            let gate = IdleStartWriteGate()
            try await channel.pipeline.addHandler(gate, position: .before(connection.duplexLogger))
            defer { connection.abortNow() }

            let starting = Task { try await connection.idle() }
            await gate.entered.wait()
            _ = try await gate.failHeldWrite { true }
            await #expect(throws: ChannelError.ioOnClosedChannel) { try await starting.value }
        }
    }

    @Test
    func idleWriteFailureFinishesStreamBeforeChannelInactive() async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let channel = try await installTransport(connection)
            connection.replaceCapabilitiesForTesting([.idle])
            let gate = IdleStartWriteGate()
            try await channel.pipeline.addHandler(gate, position: .before(connection.duplexLogger))
            let (stream, continuation) = AsyncStream<IMAPServerEvent>.makeStream()
            defer { continuation.finish(); connection.abortNow() }

            let starting = Task { try await connection.startIdleSession(continuation: continuation) }
            await gate.entered.wait()
            let handler = try #require(connection.idleHandler)
            // Socket close fails pending writes before channelInactive. Check
            // stream completion synchronously in that same event-loop turn.
            let finishedBeforeClose = try await gate.failHeldWrite { handler.hasFinishedStream }
            #expect(finishedBeforeClose)
            await #expect(throws: ChannelError.ioOnClosedChannel) { try await starting.value }
            #expect(handler.hasFinishedStream)
            if handler.hasFinishedStream {
                var iterator = stream.makeAsyncIterator()
                #expect(await iterator.next() == nil)
            }
            try await channel.closeFuture.get()
        }
    }

    @Test
    func abortFinishesReturnedIdleStream() async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let channel = try await installTransport(connection)
            connection.replaceCapabilitiesForTesting([.idle])
            defer { connection.abortNow() }
            let stream = try await connection.idle()
            let handler = try #require(connection.idleHandler)
            #expect(try await outbound(channel).contains("IDLE"))
            connection.abortNow()
            try await channel.closeFuture.get()
            #expect(handler.hasFinishedStream)
            if handler.hasFinishedStream {
                var iterator = stream.makeAsyncIterator()
                #expect(await iterator.next() == nil)
            }
        }
    }
}

private final class IdleStartWriteGate: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = IMAPClientHandler.OutboundIn
    let entered = IMAPTestSignal()
    private let lock = NSLock()
    private var held: (EventLoopPromise<Void>, EventLoop)?

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if case .part(.tagged(let command)) = unwrapOutboundIn(data),
           case .idleStart = command.command, let promise {
            lock.withLock { held = (promise, context.eventLoop) }
            entered.signal()
            return
        }
        context.write(data, promise: promise)
    }

    func failHeldWrite(_ afterFailure: @escaping @Sendable () -> Bool) async throws -> Bool {
        let held = lock.withLock { () -> (EventLoopPromise<Void>, EventLoop)? in
            defer { self.held = nil }
            return self.held
        }
        let (promise, eventLoop) = try #require(held)
        return try await eventLoop.submit {
            promise.fail(ChannelError.ioOnClosedChannel)
            return afterFailure()
        }.get()
    }
}
