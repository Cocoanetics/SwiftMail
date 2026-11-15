import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

extension IMAPBootstrapRaceTests {
    @Test
    func cancellationDoesNotWaitForForeignCancellationCallback() async throws {
        let harness = AuthenticationRaceHarness()
        let connection = await harness.server.primaryConnection
        let channel = try await harness.install(on: connection)
        let entered = IMAPTestSignal()
        let callbackEntered = IMAPTestSignal()
        let releaseProvider = IMAPTestSignal()
        let releaseCallback = DispatchSemaphore(value: 0)
        defer { releaseCallback.signal(); releaseProvider.signal(); connection.abortNow() }
        let caller = Task {
            try await connection.withOperation {
                try await connection.resolveAccessToken {
                    await withTaskCancellationHandler {
                        entered.signal()
                        await releaseProvider.wait()
                        return "late-token"
                    } onCancel: {
                        callbackEntered.signal()
                        releaseCallback.wait()
                    }
                }
            }
        }
        await entered.wait()
        let cancelling = Task.detached { caller.cancel() }
        await callbackEntered.wait()
        await #expect(throws: CancellationError.self) { try await authenticationResult(caller) }
        try await authenticationResult(Task { await cancelling.value; try Task.checkCancellation() })
        try await authenticationResult(Task { try await channel.closeFuture.get() })
        #expect(connection.channel == nil)
    }

    @Test(arguments: [false, true])
    func cancellationDuringBootstrapFencesLateTCP(initialized: Bool) async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let driver = BootstrapDriver(connection)
            defer { connection.abortNow() }
            let caller = Task { try await connection.connect() }
            let initialize = try await driver.initializer.value()
            let channel = try await activeChannel()
            if initialized { try await channel.eventLoop.flatSubmit { initialize(channel) }.get() }
            caller.cancel()
            await #expect(throws: CancellationError.self) { try await authenticationResult(caller) }
            if !initialized {
                await #expect(throws: IMAPConnectionAbortedError.self) {
                    try await channel.eventLoop.flatSubmit { initialize(channel) }.get()
                }
            }
            driver.tcp.succeed(channel)
            try await channel.closeFuture.get()
            #expect(connection.channel == nil)
        }
    }

    @Test(arguments: ["command", "handler", "PLAIN", "XOAUTH2", "APPEND", "send", "result"])
    func cancellationSettlesWhileExecutionIsHeld(path: String) async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let channel = try await installTransport(connection)
            let gate = HoldGate(path == "result" ? "response:NoopCommand" : "held")
            let finished = IMAPTestSignal()
            connection.operationOwnerFinishedForTesting = finished.signal
            defer { gate.release.signal(); connection.abortNow() }
            if path == "result" { connection.lifecycleCheckpointForTesting = gate.visit }
            if path == "handler" { connection.handlerPromiseCreatedForTesting = gate.entered.signal }
            let caller = Task {
                try await connection.withOperation { try await cancellationPath(path, connection, gate: gate) }
            }
            if path == "send" || path == "handler" {
                await gate.entered.wait()
            } else {
                var line = try await outbound(channel)
                if path == "APPEND" {
                    while !line.hasSuffix("\r\n") { line += try await outbound(channel) }
                    #expect(line.contains("{7}\r\n") && !line.contains("payload"))
                }
                if path == "result" {
                    let tag = try #require(line.split(separator: " ").first)
                    try await inbound(channel, "\(tag) OK complete\r\n")
                    await gate.entered.wait()
                }
            }
            caller.cancel()
            await #expect(throws: CancellationError.self) { try await authenticationResult(caller) }
            try await channel.closeFuture.get()
            #expect(connection.channel == nil)
            connection.lifecycleCheckpointForTesting = nil
            try await installFreshTransport(connection)
            let fresh = try connection.capturedTransport()
            gate.release.signal()
            await finished.wait()
            try connection.validateTransport(fresh)
            #expect(try await channel.readOutbound(as: ByteBuffer.self) == nil)
        }
    }

    @Test(arguments: ["command", "handler", "PLAIN", "XOAUTH2"])
    func cancellationBetweenPromiseCreationAndBinding(path: String) async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let channel = try await installTransport(connection)
            let created = IMAPTestSignal()
            let release = DispatchSemaphore(value: 0)
            let finished = IMAPTestSignal()
            connection.operationOwnerFinishedForTesting = finished.signal
            connection.handlerPromiseCreatedForTesting = { created.signal(); release.wait() }
            defer { connection.abortNow() }
            let caller = Task {
                try await connection.withOperation { try await cancellationPath(path, connection) }
            }
            await created.wait()
            caller.cancel()
            await #expect(throws: CancellationError.self) { try await authenticationResult(caller) }
            release.signal()
            await finished.wait()
            try await channel.closeFuture.get()
            #expect(try await channel.readOutbound(as: ByteBuffer.self) == nil)
        }
    }

    private func cancellationPath(_ path: String, _ connection: IMAPConnection, gate: HoldGate? = nil) async throws {
        switch path {
            case "handler":
                let _: [IMAPServerEvent] = try await connection.executeHandlerOnly(handlerType: NoopHandler.self)
            case "PLAIN": try await connection.authenticatePlainBody(username: "user", password: "secret")
            case "XOAUTH2":
                try await connection.authenticateXOAUTH2Body(email: "user@example.com", accessToken: "token")
            case "APPEND":
                _ = try await connection.executeCommandBody(AppendCommand(
                    mailboxName: "INBOX", message: "payload", flags: [], internalDate: nil))
            case "send":
                let gate = try #require(gate)
                _ = try await connection.executeCommandBody(HeldCommand(entered: gate.entered, release: gate.release))
            default: _ = try await connection.executeCommandBody(NoopCommand())
        }
    }

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

            await #expect(throws: IMAPConnectionAbortedError()) {
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
