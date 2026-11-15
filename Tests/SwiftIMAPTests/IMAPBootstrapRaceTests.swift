import Foundation
import NIO
import NIOEmbedded
import NIOIMAP
import NIOIMAPCore
import NIOSSL
import Testing
@testable import SwiftMail

/// All races are ordered by signals or actual decoder output. Held owners are
/// released in cleanup, even when an expectation fails.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPBootstrapRaceTests {
    @Test(arguments: [false, true])
    func abortBeforeInitializerSettlesBeforeLateTCP(failTCP: Bool) async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let driver = BootstrapDriver(connection)
            let connecting = Task { try await connection.connect() }
            let initialize = try await driver.initializer.value()
            let attempt = try #require(connection.lifetime.gate.withLock { connection.bootstrapAttempts.values.first })
            let settlements = IMAPTestCounter()
            attempt.greeting.observe { _ in _ = settlements.increment() }
            connection.abortNow()
            connection.abortNow()
            await #expect(throws: IMAPConnectionAbortedError()) { try await connecting.value }
            #expect(connection.channel == nil)
            #expect(settlements.value == 1)

            // Neither ordinary recovery nor another command may rearm abort.
            await #expect(throws: IMAPConnectionAbortedError()) {
                try await connection.executeCommand(NoopCommand())
            }
            let late = try await activeChannel()
            await #expect(throws: IMAPConnectionAbortedError()) {
                try await late.eventLoop.flatSubmit { initialize(late) }.get()
            }
            if failTCP { driver.tcp.fail(IMAPConcurrencyTestError.expected) } else { driver.tcp.succeed(late) }
            try await late.closeFuture.get()
            #expect(!late.isActive)
            #expect(connection.channel == nil)
            #expect(settlements.value == 1)
        }
    }

    @Test(arguments: [false, true])
    func abortDuringTCPClosesEveryRegisteredCandidate(failTCP: Bool) async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let driver = BootstrapDriver(connection)
            let connecting = Task { try await connection.connect() }
            let initialize = try await driver.initializer.value()
            let first = try await activeChannel()
            let second = try await activeChannel()
            try await first.eventLoop.flatSubmit { initialize(first) }.get()
            try await second.eventLoop.flatSubmit { initialize(second) }.get()
            connection.abortNow()
            await #expect(throws: IMAPConnectionAbortedError()) { try await connecting.value }
            try await first.closeFuture.get()
            try await second.closeFuture.get()
            if failTCP { driver.tcp.fail(IMAPConcurrencyTestError.expected) } else { driver.tcp.succeed(first) }
            #expect(!first.isActive && !second.isActive)
            #expect(connection.channel == nil)
        }
    }

    @Test(arguments: ["tcp", "published", "greeting", "discovery"])
    func abortVersusPublicationAndDiscovery(stage: String) async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let gate = HoldGate(stage)
            let oldFinished = IMAPTestSignal()
            connection.operationOwnerFinishedForTesting = oldFinished.signal
            connection.lifecycleCheckpointForTesting = gate.visit
            defer { gate.release.signal(); connection.abortNow() }
            let driver = BootstrapDriver(connection)
            let connecting = Task { try await connection.connect() }
            let channel = try await driver.initializeChannel()
            driver.tcp.succeed(channel)
            try await inbound(channel, "* OK [CAPABILITY IMAP4rev1] ready\r\n")
            await gate.entered.wait()
            #expect((connection.channel != nil) == (stage != "tcp"))
            connection.abortNow()
            await #expect(throws: IMAPConnectionAbortedError()) { try await connecting.value }
            try await channel.closeFuture.get()
            #expect(connection.channel == nil)
            #expect(connection.capabilitiesSnapshot.isEmpty)
            #expect(!connection.isAuthenticated)
            // Caller settlement is required while the old owner is still held.
            try await installFreshTransport(connection)
            let fresh = try connection.capturedTransport()
            gate.release.signal()
            await gate.exited.wait()
            await oldFinished.wait()
            try connection.validateTransport(fresh)
            #expect(connection.isAuthenticated)
        }
    }

    @Test
    func abortWhileWaitingForGreeting() async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let published = IMAPTestSignal()
            connection.lifecycleCheckpointForTesting = { stage in if stage == "published" { published.signal() } }
            let driver = BootstrapDriver(connection)
            let connecting = Task { try await connection.connect() }
            let channel = try await driver.initializeChannel()
            driver.tcp.succeed(channel)
            await published.wait()
            connection.abortNow()
            await #expect(throws: IMAPConnectionAbortedError()) { try await connecting.value }
            try await channel.closeFuture.get()
            #expect(connection.channel == nil)
        }
    }

    @Test(arguments: ["write:CapabilityCommand", "response:CapabilityCommand"])
    func abortCapabilityCommand(stage: String) async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let gate = HoldGate(stage)
            connection.lifecycleCheckpointForTesting = gate.visit
            defer { gate.release.signal(); connection.abortNow() }
            let driver = BootstrapDriver(connection)
            let connecting = Task { try await connection.connect() }
            let channel = try await driver.initializeChannel()
            driver.tcp.succeed(channel)
            try await inbound(channel, "* OK ready\r\n")
            if stage.hasPrefix("response") {
                #expect(try await outbound(channel) == "A001 CAPABILITY\r\n")
                try await inbound(channel, "* CAPABILITY IMAP4rev1 ID\r\nA001 OK done\r\n")
            }
            await gate.entered.wait()
            connection.abortNow()
            await #expect(throws: IMAPConnectionAbortedError()) { try await connecting.value }
            try await channel.closeFuture.get()
            gate.release.signal()
            await gate.exited.wait()
            #expect(try await channel.readOutbound(as: ByteBuffer.self) == nil)
            #expect(connection.capabilitiesSnapshot.isEmpty)
        }
    }

}

extension IMAPBootstrapRaceTests {
    @Test(arguments: ["LOGIN", "PLAIN", "XOAUTH2", "CAPABILITY", "NAMESPACE", "ID"])
    func abortAuthenticationAndFollowUpWithServerResponseHeld(boundary: String) async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let channel = try await installTransport(connection)
            defer { connection.abortNow() }
            let mechanism: SwiftMail.IMAPServer.AuthenticationMethod
            switch boundary {
                case "PLAIN": mechanism = .plain(username: "user", password: "secret")
                case "XOAUTH2": mechanism = .xoauth2(email: "user@example.com", accessTokenProvider: { "token" })
                default: mechanism = .login(username: "user", password: "secret")
            }
            let authentication = IMAPServer.Authentication(method: mechanism,
                                                           identification: Identification(name: "test"))
            let authenticating = Task { try await authentication.authenticate(on: connection) }
            let first = try await outbound(channel)
            #expect(first.contains(boundary == "PLAIN" || boundary == "XOAUTH2" ? boundary : "LOGIN"))
            if ["CAPABILITY", "NAMESPACE", "ID"].contains(boundary) {
                try await inbound(channel, "A001 OK authenticated\r\n")
                #expect(try await outbound(channel) == "A002 CAPABILITY\r\n")
                if boundary != "CAPABILITY" {
                    let caps = boundary == "NAMESPACE" ? "IMAP4rev1 NAMESPACE ID" : "IMAP4rev1 ID"
                    try await inbound(channel, "* CAPABILITY \(caps)\r\nA002 OK done\r\n")
                    let followUp = try await outbound(channel)
                    #expect(followUp.contains(boundary))
                }
            }
            connection.abortNow()
            await #expect(throws: IMAPConnectionAbortedError()) { try await authenticating.value }
            try await channel.closeFuture.get()
            try await installFreshTransport(connection)
            #expect(connection.isAuthenticated)
            #expect(connection.capabilitiesSnapshot == [Capability("IMAP4rev1")])
            #expect(try await channel.readOutbound(as: ByteBuffer.self) == nil)
        }
    }

    @Test(arguments: ["authenticated", "authCapabilities", "authNamespaces", "response:IDCommand"])
    func heldAuthenticationOwnerCannotCommitAfterExplicitReconnect(stage: String) async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let channel = try await installTransport(connection)
            let gate = HoldGate(stage)
            let oldFinished = IMAPTestSignal()
            connection.operationOwnerFinishedForTesting = oldFinished.signal
            connection.lifecycleCheckpointForTesting = gate.visit
            defer { gate.release.signal(); connection.abortNow() }
            let auth = IMAPServer.Authentication(method: .login(username: "user", password: "secret"),
                                                 identification: Identification(name: "test"))
            let authenticating = Task { try await auth.authenticate(on: connection) }
            _ = try await outbound(channel)
            try await inbound(channel, "A001 OK [CAPABILITY IMAP4rev1 ID] authenticated\r\n")
            if stage == "response:IDCommand" {
                #expect(try await outbound(channel).contains("ID"))
                try await inbound(channel, "* ID NIL\r\nA002 OK done\r\n")
            }
            await gate.entered.wait()
            connection.abortNow()
            await #expect(throws: IMAPConnectionAbortedError()) { try await authenticating.value }
            try await installFreshTransport(connection)
            let fresh = try connection.capturedTransport()
            gate.release.signal()
            await gate.exited.wait()
            await oldFinished.wait()
            try connection.validateTransport(fresh)
            #expect(connection.isAuthenticated)
            #expect(!connection.authenticationInProgress)
        }
    }

    @Test(arguments: ["tlsAccepted", "tlsInstalled"])
    func abortDuringSTARTTLSNeverDiscoversOnReplacement(stage: String) async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group, security: .startTLS)
            let gate = HoldGate(stage)
            let oldFinished = IMAPTestSignal()
            connection.operationOwnerFinishedForTesting = oldFinished.signal
            connection.lifecycleCheckpointForTesting = gate.visit
            defer { gate.release.signal(); connection.abortNow() }
            let driver = BootstrapDriver(connection)
            let connecting = Task { try await connection.connect() }
            let channel = try await driver.initializeChannel()
            driver.tcp.succeed(channel)
            try await inbound(channel, "* OK [CAPABILITY IMAP4rev1 STARTTLS] ready\r\n")
            #expect(try await outbound(channel) == "A001 STARTTLS\r\n")
            try await inbound(channel, "A001 OK begin TLS\r\n")
            await gate.entered.wait()
            let installed = try await channel.eventLoop.submit {
                (try? channel.pipeline.syncOperations.handler(type: NIOSSLClientHandler.self)) != nil
            }.get()
            #expect(installed == (stage == "tlsInstalled"))
            connection.abortNow()
            await #expect(throws: IMAPConnectionAbortedError()) { try await connecting.value }
            try await installFreshTransport(connection)
            let fresh = try connection.capturedTransport()
            gate.release.signal()
            await oldFinished.wait()
            try connection.validateTransport(fresh)
            #expect(connection.isAuthenticated)
        }
    }

    @Test
    func failureBeforeInitializerSettlesGreetingExactlyOnce() async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let driver = BootstrapDriver(connection)
            let connecting = Task { try await connection.connect() }
            _ = try await driver.initializer.value()
            let attempt = try #require(connection.lifetime.gate.withLock { connection.bootstrapAttempts.values.first })
            let settlements = IMAPTestCounter()
            attempt.greeting.observe { _ in _ = settlements.increment() }
            driver.tcp.fail(IMAPConcurrencyTestError.expected)
            await #expect(throws: IMAPConcurrencyTestError.expected) { try await connecting.value }
            connection.abortNow()
            #expect(settlements.value == 1)
            #expect(connection.channel == nil)
        }
    }

    @Test
    func initializerFailureSettlesGreetingExactlyOnce() async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            connection.channelInitializationForTesting = { _ in throw IMAPConcurrencyTestError.expected }
            let driver = BootstrapDriver(connection)
            let connecting = Task { try await connection.connect() }
            let initialize = try await driver.initializer.value()
            let attempt = try #require(connection.lifetime.gate.withLock { connection.bootstrapAttempts.values.first })
            let settlements = IMAPTestCounter()
            attempt.greeting.observe { _ in _ = settlements.increment() }
            let channel = try await activeChannel()
            do {
                try await channel.eventLoop.flatSubmit { initialize(channel) }.get()
                Issue.record("Expected initializer failure")
            } catch {
                driver.tcp.fail(error)
            }
            await #expect(throws: IMAPConcurrencyTestError.expected) { try await connecting.value }
            #expect(settlements.value == 1)
            try await channel.closeFuture.get()
        }
    }

    @Test
    func latePreparedWriteAndCleanupCannotTouchFreshCommand() async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let old = try await installTransport(connection)
            let entered = IMAPTestSignal()
            let release = IMAPTestSignal()
            let oldFinished = IMAPTestSignal()
            connection.operationOwnerFinishedForTesting = oldFinished.signal
            defer { release.signal(); connection.abortNow() }
            let command = Task {
                try await connection.executeCommand(HeldCommand(entered: entered, release: release))
            }
            await entered.wait()
            connection.abortNow()
            await #expect(throws: IMAPConnectionAbortedError()) { try await command.value }
            try await installFreshTransport(connection)
            let fresh = try #require(connection.channel as? NIOAsyncTestingChannel)
            let pending = Task { try await connection.noop() }
            let line = try await outbound(fresh)
            let tag = try #require(line.split(separator: " ").first)
            let buffer = connection.responseBuffer
            #expect(buffer.hasActiveHandler)
            release.signal()
            await oldFinished.wait()
            #expect(buffer.hasActiveHandler)
            #expect(connection.isAuthenticated)
            #expect(try await old.readOutbound(as: ByteBuffer.self) == nil)
            try await inbound(fresh, "\(tag) OK done\r\n")
            _ = try await pending.value
        }
    }

}

extension IMAPBootstrapRaceTests {
    @Test
    func abortDuringDisconnectClosesCapturedSocketBeforeOwnerReturns() async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let old = try await installTransport(connection)
            let entered = IMAPTestSignal()
            let release = IMAPTestSignal()
            let oldFinished = IMAPTestSignal()
            defer { release.signal(); connection.abortNow() }
            connection.operationOwnerFinishedForTesting = oldFinished.signal
            connection.beforeTransportCloseForTesting = { _ in entered.signal(); await release.wait() }
            let disconnecting = Task { try await connection.disconnect() }
            await entered.wait()
            connection.abortNow()
            await #expect(throws: IMAPConnectionAbortedError()) { try await disconnecting.value }
            try await old.closeFuture.get()
            try await installFreshTransport(connection)
            connection.lostAuthenticatedSession = true
            release.signal()
            await oldFinished.wait()
            #expect(connection.lostAuthenticatedSession)
            #expect(connection.isAuthenticated)
        }
    }

    @Test
    func oldCloseAndBYECannotClearReplacementInSameGeneration() async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let oldChannel = try await installTransport(connection)
            let old = try connection.capturedTransport()
            let entered = IMAPTestSignal()
            let release = IMAPTestSignal()
            defer { release.signal(); connection.abortNow() }
            connection.beforeTransportCloseForTesting = { context in
                if context === old { entered.signal(); await release.wait() }
            }
            let closing = Task { await connection.closeTransport(old) }
            await entered.wait()
            let freshChannel = try await installTransport(connection)
            let fresh = try connection.capturedTransport()
            connection.markSessionAuthenticated()
            try await inbound(freshChannel, "* 7 EXISTS\r\n")
            release.signal()
            await closing.value
            await connection.handleConnectionTerminationInResponses([.fatal(ResponseText(text: "old BYE"))],
                                                                    context: old)
            try connection.validateTransport(fresh)
            #expect(old.generation == fresh.generation)
            #expect(old.id != fresh.id)
            #expect(old.responseBuffer !== fresh.responseBuffer)
            #expect(old.duplexLogger !== fresh.duplexLogger)
            #expect(connection.isAuthenticated)
            #expect(fresh.responseBuffer.bufferedCount == 1)
            #expect(!oldChannel.isActive)
        }
    }

}
