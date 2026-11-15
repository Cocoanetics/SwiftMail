import Foundation
import NIO
import NIOEmbedded
import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

/// Intentionally ignores cancellation, like an OAuth library backed by a callback.
final class HeldAuthenticationProvider: @unchecked Sendable {
    let entered = IMAPTestSignal()
    let release = IMAPTestSignal()
    let returned = IMAPTestSignal()
    let calls = IMAPTestCounter()
    let fails: Bool

    init(fails: Bool = false) { self.fails = fails }

    func token() async throws -> String {
        _ = calls.increment()
        entered.signal()
        await release.wait()
        defer { returned.signal() }
        if fails { throw IMAPConcurrencyTestError.expected }
        return "old-token"
    }
}

/// Holds the shared attempt's pre-queue token request while allowing queue-owned
/// reconnect authentication to obtain a second token immediately.
final class OvertakingAuthenticationProvider: @unchecked Sendable {
    let firstEntered = IMAPTestSignal()
    let releaseFirst = IMAPTestSignal()
    let secondEntered = IMAPTestSignal()
    let calls = IMAPTestCounter()

    func token() async -> String {
        if calls.increment() == 1 {
            firstEntered.signal()
            await releaseFirst.wait()
            return "shared-token"
        }
        secondEntered.signal()
        return "reconnect-token"
    }
}

enum AuthenticationRaceError: Error { case watchdog }

/// The timeout is only a failure watchdog; signals and observed waiter counts
/// establish ordering. No structured race waits for a held provider at exit.
func authenticationResult<Value>(_ task: Task<Value, Error>) async throws -> Value {
    let sink = IMAPTerminal<Value>()
    let observer = Task { sink.complete(await task.result) }
    let watchdog = Task {
        try await Task.sleep(nanoseconds: 1_000_000_000)
        sink.complete(.failure(AuthenticationRaceError.watchdog))
    }
    defer { watchdog.cancel(); observer.cancel() }
    return try await sink.value()
}

func authenticationWaitUntil(_ condition: @escaping () async -> Bool) async throws {
    try await authenticationResult(Task {
        while !(await condition()) { try Task.checkCancellation(); await Task.yield() }
    })
}

struct AuthenticationRaceHarness {
    let server = SwiftMail.IMAPServer(host: "localhost", port: 143, useTLS: false)

    func install(on connection: IMAPConnection) async throws -> NIOAsyncTestingChannel {
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 143))
        try await channel.addIMAPClientHandler()
        try await channel.pipeline.addHandler(connection.duplexLogger)
        try await channel.pipeline.addHandler(connection.responseBuffer)
        connection.replaceChannelForTesting(channel)
        connection.replaceCapabilitiesForTesting([
            Capability("IMAP4rev1"), .saslIR, .authenticate(AuthenticationMechanism("XOAUTH2")!), .id
        ])
        return channel
    }

    func configuration(_ provider: HeldAuthenticationProvider) -> SwiftMail.IMAPServer.Authentication {
        .init(method: .xoauth2(email: "user@example.com", accessTokenProvider: { try await provider.token() }),
              identification: Identification(name: "SwiftMailTests"))
    }

    func inbound(_ channel: NIOAsyncTestingChannel, _ text: String) async throws {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        try await channel.writeInbound(buffer)
    }

    func outbound(_ channel: NIOAsyncTestingChannel) async throws -> String {
        try await authenticationResult(Task {
            while true {
                if var buffer = try await channel.readOutbound(as: ByteBuffer.self) {
                    return buffer.readString(length: buffer.readableBytes) ?? ""
                }
                try Task.checkCancellation()
                await Task.yield()
            }
        })
    }

    func completeOAuth(on channel: NIOAsyncTestingChannel) async throws {
        let authenticate = try await outbound(channel)
        #expect(authenticate.contains(" AUTHENTICATE XOAUTH2 "))
        let tag = try #require(authenticate.split(separator: " ").first)
        try await inbound(channel, "\(tag) OK [CAPABILITY IMAP4rev1 AUTH=XOAUTH2 ID] authenticated\r\n")
        let identify = try await outbound(channel)
        #expect(identify.contains(" ID ("))
        let idTag = try #require(identify.split(separator: " ").first)
        try await inbound(channel, "* ID NIL\r\n\(idTag) OK identified\r\n")
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SharedAuthenticationGenerationTests {
    @Test
    func queueOwnedRecoveryCanOvertakePreQueueOAuthWithoutDuplicateAuthentication() async throws {
        let harness = AuthenticationRaceHarness()
        let connection = await harness.server.primaryConnection
        let stale = try await harness.install(on: connection)
        connection.markSessionAuthenticated()
        try await stale.close()
        let provider = OvertakingAuthenticationProvider()
        let authentication = SwiftMail.IMAPServer.Authentication(
            method: .xoauth2(email: "user@example.com", accessTokenProvider: { await provider.token() }),
            identification: Identification(name: "SwiftMailTests")
        )
        await harness.server.replaceAuthenticationForTesting(authentication)
        let replacementCell = IMAPTerminal<NIOAsyncTestingChannel>()
        connection.replaceConnectForTesting {
            do {
                replacementCell.complete(.success(try await harness.install(on: connection)))
            } catch {
                replacementCell.complete(.failure(error))
                throw error
            }
        }
        defer { provider.releaseFirst.signal(); connection.abortNow() }

        let selecting = Task { try await harness.server.selectMailbox("INBOX") }
        await provider.firstEntered.wait()
        #expect(connection.lifetime.reservationCount == 0)

        let noop = Task { try await harness.server.noop() }
        let replacement = try await replacementCell.value()
        await provider.secondEntered.wait()
        try await harness.completeOAuth(on: replacement)
        let noopLine = try await harness.outbound(replacement)
        #expect(noopLine.contains(" NOOP"))
        let noopTag = try #require(noopLine.split(separator: " ").first)
        try await harness.inbound(replacement, "\(noopTag) OK noop completed\r\n")
        _ = try await authenticationResult(noop)

        provider.releaseFirst.signal()
        let selectLine = try await harness.outbound(replacement)
        #expect(selectLine.contains(" SELECT "), "Shared recovery must not authenticate an already recovered session")
        #expect(provider.calls.value == 2)
        let selectTag = try #require(selectLine.split(separator: " ").first)
        try await harness.inbound(replacement, "* 0 EXISTS\r\n\(selectTag) OK selected\r\n")
        _ = try await authenticationResult(selecting)
        #expect(connection.isAuthenticated)
        #expect(try await replacement.readOutbound(as: ByteBuffer.self) == nil)
    }

    @Test(arguments: [false, true])
    func namedRearmKeepsFreshAttemptWhenOldProviderCompletes(fails: Bool) async throws {
        let harness = AuthenticationRaceHarness()
        let connection = await harness.server.primaryConnection
        let old = try await harness.install(on: connection)
        let oldProvider = HeldAuthenticationProvider(fails: fails)
        let freshProvider = HeldAuthenticationProvider()
        let calls = IMAPTestCounter()
        let named = IMAPNamedConnection(name: "rearmed", connection: connection, authenticateOnConnection: {
            let provider = calls.increment() == 1 ? oldProvider : freshProvider
            try await harness.configuration(provider).authenticate(on: $0)
        })
        defer { oldProvider.release.signal(); freshProvider.release.signal(); connection.abortNow() }
        let leader = Task { try await named.ensureAuthenticated() }
        await oldProvider.entered.wait()
        let follower = Task { try await named.ensureAuthenticated() }
        try await authenticationWaitUntil { await named.authenticationAttemptForTesting?.waiterCount == 2 }
        let oldAttempt = try #require(await named.authenticationAttemptForTesting)
        connection.abortNow()
        await #expect(throws: IMAPConnectionAbortedError()) { try await authenticationResult(leader) }
        await #expect(throws: IMAPConnectionAbortedError()) { try await authenticationResult(follower) }
        connection.replaceConnectForTesting { _ = try await harness.install(on: connection) }
        let reconnect = Task { try await named.connect() }
        await freshProvider.entered.wait()
        let fresh = try #require(connection.channel as? NIOAsyncTestingChannel)
        let newAttempt = try #require(await named.authenticationAttemptForTesting)
        #expect(newAttempt.id != oldAttempt.id)
        #expect(newAttempt.generation != oldAttempt.generation)
        oldProvider.release.signal()
        await oldProvider.returned.wait()
        #expect(await named.authenticationAttemptForTesting?.id == newAttempt.id)
        #expect(try await old.readOutbound(as: ByteBuffer.self) == nil)
        #expect(try await fresh.readOutbound(as: ByteBuffer.self) == nil)
        freshProvider.release.signal()
        try await harness.completeOAuth(on: fresh)
        try await authenticationResult(reconnect)
        #expect(connection.isAuthenticated)
        #expect(await named.authenticationAttemptForTesting == nil)
        #expect(try await fresh.readOutbound(as: ByteBuffer.self) == nil)
    }

    @Test
    func namedFollowerWaitsForIdentificationAfterCredentialsAreAccepted() async throws {
        let harness = AuthenticationRaceHarness()
        let connection = await harness.server.primaryConnection
        let channel = try await harness.install(on: connection)
        let configuration = SwiftMail.IMAPServer.Authentication(
            method: .login(username: "user", password: "secret"), identification: Identification(name: "test")
        )
        let named = IMAPNamedConnection(name: "discovery", connection: connection, authenticateOnConnection: {
            try await configuration.authenticate(on: $0)
        })
        defer { connection.abortNow() }
        let leader = Task { try await named.ensureAuthenticated() }
        #expect(try await harness.outbound(channel).contains(" LOGIN "))
        try await harness.inbound(channel, "A001 OK [CAPABILITY IMAP4rev1 ID] authenticated\r\n")
        #expect(try await harness.outbound(channel).contains(" ID ("))
        #expect(connection.isAuthenticated, "Credential acceptance precedes discovery completion")
        let follower = Task { try await named.ensureAuthenticated() }
        try await authenticationWaitUntil { await named.authenticationAttemptForTesting?.waiterCount == 2 }
        try await harness.inbound(channel, "* ID NIL\r\nA002 OK identified\r\n")
        try await authenticationResult(leader)
        try await authenticationResult(follower)
        #expect(try await channel.readOutbound(as: ByteBuffer.self) == nil)
    }

    @Test(arguments: [false, true])
    func abortSettlesOAuthWaitersBeforeProviderReleaseAndLateCompletionCannotAuthenticate(fails: Bool) async throws {
        let harness = AuthenticationRaceHarness()
        let connection = await harness.server.primaryConnection
        let old = try await harness.install(on: connection)
        let provider = HeldAuthenticationProvider(fails: fails)
        let workerExited = IMAPTestSignal()
        let configuration = harness.configuration(provider)
        let named = IMAPNamedConnection(name: "oauth", connection: connection, authenticateOnConnection: {
            defer { workerExited.signal() }
            try await configuration.authenticate(on: $0)
        })
        defer { provider.release.signal(); connection.abortNow() }
        let callerSettlements = IMAPTestCounter()
        let leader = Task {
            defer { _ = callerSettlements.increment() }
            try await named.ensureAuthenticated()
        }
        await provider.entered.wait()
        #expect(connection.lifetime.reservationCount == 0, "Provider wait must precede command queue admission")
        let follower = Task {
            defer { _ = callerSettlements.increment() }
            try await named.ensureAuthenticated()
        }
        try await authenticationWaitUntil { await named.authenticationAttemptForTesting?.waiterCount == 2 }
        let attempt = try #require(await named.authenticationAttemptForTesting)
        let settlements = IMAPTestCounter()
        attempt.terminal.observe { _ in _ = settlements.increment() }
        connection.abortNow()
        connection.abortNow()
        await #expect(throws: IMAPConnectionAbortedError()) { try await authenticationResult(leader) }
        await #expect(throws: IMAPConnectionAbortedError()) { try await authenticationResult(follower) }
        try await authenticationResult(Task { await workerExited.wait() })
        #expect(settlements.value == 1)
        #expect(callerSettlements.value == 2)
        #expect(!connection.isAuthenticated)
        #expect(await named.lastActivity == nil)
        #expect(try await old.readOutbound(as: ByteBuffer.self) == nil)
        provider.release.signal()
        await provider.returned.wait()
        #expect(try await old.readOutbound(as: ByteBuffer.self) == nil)
        #expect(!connection.isAuthenticated)
        #expect(settlements.value == 1)
        #expect(callerSettlements.value == 2)
    }

    @Test(arguments: [false, true], [false, true])
    func primaryAbortRearmAndNewAttemptSurviveOldProvider(
        fails: Bool, releaseAfterNewAuthentication: Bool
    ) async throws {
        let harness = AuthenticationRaceHarness()
        let connection = await harness.server.primaryConnection
        let old = try await harness.install(on: connection)
        let provider = HeldAuthenticationProvider(fails: fails)
        defer { provider.release.signal(); connection.abortNow() }
        await harness.server.replaceAuthenticationForTesting(harness.configuration(provider))
        let leader = Task { try await harness.server.ensurePrimaryConnectionAuthenticated() }
        await provider.entered.wait()
        let follower = Task { try await harness.server.ensurePrimaryConnectionAuthenticated() }
        try await authenticationWaitUntil { await harness.server.primaryAuthenticationInFlight?.waiterCount == 2 }
        let oldAttempt = try #require(await harness.server.primaryAuthenticationInFlight)
        connection.abortNow()
        await #expect(throws: IMAPConnectionAbortedError()) { try await authenticationResult(leader) }
        await #expect(throws: IMAPConnectionAbortedError()) { try await authenticationResult(follower) }

        // Exercise the explicit connect path that alone is allowed to rearm.
        connection.replaceConnectForTesting { _ = try await harness.install(on: connection) }
        try await harness.server.connect()
        let fresh = try #require(connection.channel as? NIOAsyncTestingChannel)
        let freshProvider = HeldAuthenticationProvider()
        defer { freshProvider.release.signal() }
        await harness.server.replaceAuthenticationForTesting(harness.configuration(freshProvider))
        let newLeader = Task { try await harness.server.ensurePrimaryConnectionAuthenticated() }
        await freshProvider.entered.wait()
        let newAttempt = try #require(await harness.server.primaryAuthenticationInFlight)
        #expect(newAttempt.id != oldAttempt.id)
        #expect(newAttempt.generation != oldAttempt.generation)
        if !releaseAfterNewAuthentication {
            provider.release.signal()
            await provider.returned.wait()
        }
        #expect(await harness.server.primaryAuthenticationInFlight?.id == newAttempt.id)
        #expect(!connection.isAuthenticated)
        #expect(try await old.readOutbound(as: ByteBuffer.self) == nil)
        #expect(try await fresh.readOutbound(as: ByteBuffer.self) == nil)
        freshProvider.release.signal()
        try await harness.completeOAuth(on: fresh)
        try await authenticationResult(newLeader)
        provider.release.signal()
        await provider.returned.wait()
        #expect(connection.isAuthenticated)
        #expect(await harness.server.primaryAuthenticationInFlight == nil)
        #expect(try await fresh.readOutbound(as: ByteBuffer.self) == nil)
    }

    @Test(arguments: [false, true])
    func primaryWaitersCancelIndependently(cancelInitiator: Bool) async throws {
        let harness = AuthenticationRaceHarness()
        let connection = await harness.server.primaryConnection
        let channel = try await harness.install(on: connection)
        let provider = HeldAuthenticationProvider()
        defer { provider.release.signal(); connection.abortNow() }
        await harness.server.replaceAuthenticationForTesting(harness.configuration(provider))
        let initiator = Task { try await harness.server.ensurePrimaryConnectionAuthenticated() }
        await provider.entered.wait()
        let follower = Task { try await harness.server.ensurePrimaryConnectionAuthenticated() }
        try await authenticationWaitUntil { await harness.server.primaryAuthenticationInFlight?.waiterCount == 2 }
        let cancelled = cancelInitiator ? initiator : follower
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await authenticationResult(cancelled) }
        #expect(await harness.server.primaryAuthenticationInFlight?.waiterCount == 1)
        #expect(provider.calls.value == 1)
        provider.release.signal()
        try await harness.completeOAuth(on: channel)
        try await authenticationResult(cancelInitiator ? follower : initiator)
        #expect(connection.isAuthenticated)
    }

    @Test
    func directlyOwnedOAuthCancellationClosesTransportAndFencesLateToken() async throws {
        let harness = AuthenticationRaceHarness()
        let connection = await harness.server.primaryConnection
        let old = try await harness.install(on: connection)
        let provider = HeldAuthenticationProvider()
        let finished = IMAPTestSignal()
        connection.operationOwnerFinishedForTesting = finished.signal
        defer { provider.release.signal(); connection.abortNow() }
        let authentication = harness.configuration(provider)
        let caller = Task {
            try await connection.withOperation { try await authentication.authenticateBody(on: connection) }
        }
        await provider.entered.wait()
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await authenticationResult(caller) }
        try await old.closeFuture.get()
        #expect(!connection.isAuthenticated)
        connection.lifetime.rearm()
        let fresh = try await harness.install(on: connection)
        provider.release.signal()
        await provider.returned.wait()
        await finished.wait()
        #expect(connection.channel === fresh)
        #expect(!connection.isAuthenticated)
        #expect(try await fresh.readOutbound(as: ByteBuffer.self) == nil)
    }
}
