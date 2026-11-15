import NIO
import Testing
@testable import SwiftMail

extension IMAPBootstrapRaceTests {
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
