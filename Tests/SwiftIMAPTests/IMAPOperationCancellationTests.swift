import Foundation
import NIO
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPOperationCancellationTests {
    @Test(arguments: [false, true])
    func preCancelledEntryDoesNotLaunchOwnerOrAbortTransport(operationScope: Bool) async throws {
        try await withEventLoopGroup { group in
            let harness = IMAPBootstrapRaceTests()
            let connection = harness.makeConnection(group)
            let channel = try await harness.installTransport(connection)
            defer { connection.abortNow() }
            let enter = IMAPTestSignal()
            let executions = IMAPTestCounter()
            let owners = IMAPTestCounter()
            connection.operationOwnerFinishedForTesting = { _ = owners.increment() }
            let cancelled = Task<Int, Error> {
                await enter.wait()
                if operationScope {
                    return try await connection.withOperationScope {
                        _ = executions.increment()
                        return 42
                    }
                }
                return try await connection.withOperation {
                    _ = executions.increment()
                    return 42
                }
            }
            cancelled.cancel()
            enter.signal()
            await #expect(throws: CancellationError.self) { try await authenticationResult(cancelled) }
            #expect(executions.value == 0)
            #expect(owners.value == 0)
            #expect(connection.lifetime.reservationCount == 0)
            #expect(channel.isActive)
            #expect(try await connection.withOperation { 7 } == 7)
        }
    }

    @Test
    func queuedCancellationPreservesActiveCommandAndSurvivors() async throws {
        try await withEventLoopGroup { group in
            let harness = IMAPBootstrapRaceTests()
            let connection = harness.makeConnection(group)
            let channel = try await harness.installTransport(connection)
            let entered = IMAPTestSignal()
            let release = IMAPTestSignal()
            defer { release.signal(); connection.abortNow() }
            let active = Task {
                try await connection.withOperation { entered.signal(); await release.wait() }
            }
            await entered.wait()
            let queued = IMAPTestSignal()
            connection.commandQueue.testHooks.didEnqueue = queued.signal
            let cancelled = Task {
                try await connection.withOperation { Issue.record("Cancelled queued operation ran") }
            }
            await queued.wait()
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await authenticationResult(cancelled) }
            #expect(channel.isActive)
            #expect(connection.lifetime.reservationCount == 1)
            let survivor = Task { try await connection.withOperation { 42 } }
            release.signal()
            try await active.value
            #expect(try await survivor.value == 42)
        }
    }

    @Test
    func completedOperationLateCancellationCannotAbortNextOwner() async throws {
        try await withEventLoopGroup { group in
            let harness = IMAPBootstrapRaceTests()
            let connection = harness.makeConnection(group)
            let channel = try await harness.installTransport(connection)
            let original = IMAPTerminal<OperationToken>()
            let completed = Task {
                try await connection.withOperation {
                    original.complete(.success(try #require(connection.operationToken)))
                    return 7
                }
            }
            #expect(try await completed.value == 7)
            let token = try await original.value()
            let entered = IMAPTestSignal()
            let release = IMAPTestSignal()
            defer { release.signal(); connection.abortNow() }
            let next = Task {
                try await connection.withOperation { entered.signal(); await release.wait(); return 42 }
            }
            await entered.wait()
            completed.cancel()
            // Also deliver the completed operation's callback while another
            // token owns execution, rather than relying on task scheduling.
            connection.abortNow(cancelling: token)
            #expect(channel.isActive)
            #expect(connection.lifetime.reservationCount == 1)
            release.signal()
            #expect(try await next.value == 42)
        }
    }

    #if os(macOS) || os(Linux)
    @Test
    func activeFetchCancellationSettlesCallersAndClosesSocketBeforeReplyRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cur"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("new"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = IMAPTestServer.Script(connectionNumber: 1, occurrence: 2, actions: [
            .hold("fetch-reply"), .taggedCompletion("OK FETCH completed")
        ])
        let server = try IMAPTestServer(scripts: [script], maildirURL: root)
        try server.start()
        try await server.run {
            try await withEventLoopGroup { group in
                let connection = socketConnection(server, group: group)
                defer { connection.abortNow() }
                try await connection.connect()
                let drained = IMAPTestSignal()
                let finished = IMAPTestCounter()
                connection.operationOwnerFinishedForTesting = { if finished.increment() == 3 { drained.signal() } }
                let active = Task {
                    try await connection.withOperationScope {
                        try await connection.executeCommand(FetchRawMessagesCommand(
                            identifierSet: SwiftMail.UIDSet(SwiftMail.UID(1)...SwiftMail.UID(1)),
                            sink: { _, _ in }))
                    }
                }
                let held = try await server.waitForEvent(.replyHeld, run: server.runID, detail: "fetch-reply")
                #expect(server.commandLog.last?.contains("UID FETCH") == true)
                let enqueued = AsyncStream<Void>.makeStream()
                defer { enqueued.continuation.finish() }
                connection.commandQueue.testHooks.didEnqueue = { enqueued.continuation.yield(()) }
                var iterator = enqueued.stream.makeAsyncIterator()
                let first = Task { try await connection.noop() }
                await iterator.next()
                let second = Task { try await connection.noop() }
                await iterator.next()
                active.cancel()
                await #expect(throws: CancellationError.self) { try await authenticationResult(active) }
                for waiter in [first, second] {
                    await #expect(throws: IMAPConnectionAbortedError.self) {
                        try await authenticationResult(waiter)
                    }
                }
                _ = try await server.waitForConnectionEnd(run: server.runID, connection: held.connection)
                #expect(!server.release(try #require(held.command), gate: "fetch-reply"))
                #expect(server.commandLog.count == 2)
                // Caller settlement precedes worker cleanup. Keep the test's
                // event loops alive until all three owners have unwound.
                try await authenticationResult(Task { await drained.wait(); try Task.checkCancellation() })
            }
        }
        #expect(server.fixtureFailures.isEmpty)
    }

    @Test(arguments: [true, false])
    func commandAfterActiveFetchCancellationFollowsReconnectPolicy(reconnects: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cur"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("new"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = IMAPTestServer.Script(connectionNumber: 1, occurrence: 2, actions: [
            .hold("fetch-reply"), .taggedCompletion("OK FETCH completed")
        ])
        let server = try IMAPTestServer(scripts: [script], maildirURL: root)
        try server.start()
        try await server.run {
            try await withEventLoopGroup { group in
                let connection = socketConnection(server, group: group)
                defer { connection.abortNow() }
                try await connection.connect()
                connection.reconnectsInsideCommands = reconnects
                let ownerFinished = IMAPTestSignal()
                connection.operationOwnerFinishedForTesting = ownerFinished.signal
                let active = Task {
                    try await connection.executeCommand(FetchRawMessagesCommand(
                        identifierSet: SwiftMail.UIDSet(SwiftMail.UID(1)...SwiftMail.UID(1)),
                        sink: { _, _ in }))
                }
                let held = try await server.waitForEvent(.replyHeld, run: server.runID,
                                                         detail: "fetch-reply")
                active.cancel()
                await #expect(throws: CancellationError.self) { try await authenticationResult(active) }
                _ = try await server.waitForConnectionEnd(run: server.runID, connection: held.connection)
                await ownerFinished.wait()
                connection.operationOwnerFinishedForTesting = nil

                if reconnects {
                    _ = try await connection.noop()
                    #expect(server.commandLog.last?.contains(" NOOP") == true)
                    #expect(server.events.contains { $0.kind == .accepted && $0.connection.number == 2 })
                } else {
                    let error = await #expect(throws: IMAPError.self) { try await connection.noop() }
                    guard case .connectionFailed? = error else {
                        Issue.record("Expected connectionFailed, got \(String(describing: error))")
                        return
                    }
                    #expect(!server.events.contains { $0.connection.number == 2 })
                }
                #expect(!server.release(try #require(held.command), gate: "fetch-reply"))
            }
        }
        #expect(server.fixtureFailures.isEmpty)
    }

    private func socketConnection(_ server: IMAPTestServer, group: EventLoopGroup) -> IMAPConnection {
        IMAPConnection(host: "127.0.0.1", port: server.port, transportSecurity: .plainText,
                       minimumTLSVersion: .tlsv12, group: group, loggerLabel: "test.cancel",
                       outboundLabel: "test.cancel.out", inboundLabel: "test.cancel.in",
                       connectionID: "cancel", connectionRole: "test", parserLimits: .default, minimumCommandTimeoutSeconds: 0)
    }
    #endif
}

/// Models a foreign OAuth implementation whose synchronous cancellation hook
/// cannot return until external cleanup releases it.
private final class BlockingOAuthProvider: @unchecked Sendable {
    let entered = IMAPTestSignal()
    let cancellationEntered = IMAPTestSignal()
    let returned = IMAPTestSignal()
    let releaseCancellation = DispatchSemaphore(value: 0)

    func token() async throws -> String {
        entered.signal()
        defer { returned.signal() }
        return try await withTaskCancellationHandler {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return "late-token"
        } onCancel: {
            cancellationEntered.signal()
            releaseCancellation.wait()
        }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPOAuthCancellationTests {
    @Test
    func activeCancellationSettlesCollateralBeforeBlockingProviderCleanupReturns() async throws {
        let harness = AuthenticationRaceHarness()
        let connection = await harness.server.primaryConnection
        let stale = try await harness.install(on: connection)
        connection.markSessionAuthenticated()
        try await stale.close()
        let provider = BlockingOAuthProvider()
        let ownersDrained = IMAPTestSignal()
        let owners = IMAPTestCounter()
        connection.operationOwnerFinishedForTesting = {
            if owners.increment() == 2 { ownersDrained.signal() }
        }
        connection.replaceConnectForTesting { _ = try await harness.install(on: connection) }
        await harness.server.replaceAuthenticationForTesting(.init(
            method: .xoauth2(email: "user@example.com", accessTokenProvider: { try await provider.token() }),
            identification: nil
        ))
        defer { provider.releaseCancellation.signal(); connection.abortNow() }

        let active = Task { try await connection.noop() }
        await provider.entered.wait()
        let collateral = Task { try await connection.noop() }
        try await authenticationWaitUntil { connection.lifetime.reservationCount == 2 }
        let cancellation = Task.detached { active.cancel() }
        try await authenticationResult(Task { await provider.cancellationEntered.wait() })

        await #expect(throws: CancellationError.self) { try await authenticationResult(active) }
        await #expect(throws: IMAPConnectionAbortedError.self) {
            try await authenticationResult(collateral)
        }
        provider.releaseCancellation.signal()
        await provider.returned.wait()
        await cancellation.value
        try await authenticationResult(Task { await ownersDrained.wait(); try Task.checkCancellation() })
    }
}
