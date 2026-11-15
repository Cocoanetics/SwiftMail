import NIO
import Testing
@testable import SwiftMail

extension IMAPBootstrapRaceTests {
    @Test(arguments: [false, true])
    func immediateDisconnectClosesPublishedBootstrapWhileGreetingIsPending(
        commandReconnect: Bool
    ) async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let published = IMAPTestSignal()
            connection.lifecycleCheckpointForTesting = { stage in
                if stage == "published" { published.signal() }
            }
            let driver = BootstrapDriver(connection)
            let operation = Task<Void, Error> {
                if commandReconnect {
                    _ = try await connection.noop()
                } else {
                    try await connection.connect()
                }
            }
            let channel = try await driver.initializeChannel()
            driver.tcp.succeed(channel)
            await published.wait()
            #expect(connection.channel === channel)
            #expect(connection.lifetime.gate.withLock {
                connection.bootstrapAttempts.values.flatMap(\.candidates).contains {
                    $0 === connection.transport
                }
            })

            try await connection.disconnectImmediately()
            do {
                try await authenticationResult(operation)
                Issue.record("Published bootstrap succeeded after immediate disconnect")
            } catch {
                #expect(!(error is AuthenticationRaceError))
            }
            try await channel.closeFuture.get()
            #expect(!channel.isActive)
            #expect(connection.channel == nil)
            #expect(connection.lifetime.gate.withLock { connection.bootstrapAttempts.isEmpty })
        }
    }

    @Test(arguments: [false, true], [false, true])
    func immediateDisconnectClaimsBootstrapBeforePublication(
        commandReconnect: Bool,
        registerCandidate: Bool
    ) async throws {
        try await withEventLoopGroup { group in
            let connection = makeConnection(group)
            let driver = BootstrapDriver(connection)
            let operation = Task<Void, Error> {
                if commandReconnect {
                    _ = try await connection.noop()
                } else {
                    try await connection.connect()
                }
            }
            let initialize = try await driver.initializer.value()
            let channel = try await activeChannel()
            if registerCandidate {
                try await channel.eventLoop.flatSubmit { initialize(channel) }.get()
            }

            try await connection.disconnectImmediately()
            do {
                try await authenticationResult(operation)
                Issue.record("Bootstrap succeeded after immediate disconnect")
            } catch {
                #expect(!(error is AuthenticationRaceError))
            }
            #expect(connection.channel == nil)
            #expect(connection.lifetime.gate.withLock { connection.bootstrapAttempts.isEmpty })

            if registerCandidate {
                try await channel.closeFuture.get()
            } else {
                await #expect(throws: IMAPConnectionAbortedError.self) {
                    try await channel.eventLoop.flatSubmit { initialize(channel) }.get()
                }
            }
            driver.tcp.succeed(channel)
            try await channel.closeFuture.get()
            #expect(!channel.isActive)
            #expect(try await connection.withOperation { 42 } == 42)
        }
    }
}
