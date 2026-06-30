import Foundation
import NIO
import NIOIMAPCore
import Testing
@testable import SwiftMail

private actor AuthenticationGate {
    private var starts = 0
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func startAndWait() async {
        starts += 1
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func startCount() -> Int {
        starts
    }

    func releaseAll() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPNamedConnectionTests {
    private struct NamedConnectionHarness {
        let named: IMAPNamedConnection
        let group: MultiThreadedEventLoopGroup

        func shutdown() async {
            try? await group.shutdownGracefully()
        }
    }

    private func makeConnection(
        name: String = "test",
        authenticate: @escaping @Sendable (IMAPConnection) async throws -> Void = { _ in }
    ) -> NamedConnectionHarness {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connection = IMAPConnection(
            host: "localhost",
            port: 1,
            useTLS: false,
            group: group,
            loggerLabel: "test.imap",
            outboundLabel: "test.imap.out",
            inboundLabel: "test.imap.in",
            connectionID: "test-\(name)",
            connectionRole: "test"
        )
        let named = IMAPNamedConnection(name: name, connection: connection, authenticateOnConnection: authenticate)
        return NamedConnectionHarness(named: named, group: group)
    }

    private func waitForAuthenticationWaiter(
        on named: IMAPNamedConnection,
        gate: AuthenticationGate
    ) async throws {
        for _ in 0..<100 {
            if await named.authenticationWaiterCountForTesting == 1 {
                return
            }
            if await gate.startCount() > 1 {
                Issue.record("Expected second authentication request to wait behind the leader")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        Issue.record("Expected second authentication request to park as a waiter")
    }

    @Test
    func lastActivityIsNilBeforeAnyCommands() async {
        let harness = makeConnection()

        let activity = await harness.named.lastActivity
        #expect(activity == nil)
        await harness.shutdown()
    }

    @Test
    func lastActivityRemainsNilAfterFailedCommand() async {
        // Authentication closure throws before executeCommand reaches the
        // underlying connection, so lastActivity must stay nil and no transport
        // should be opened.
        let harness = makeConnection(authenticate: { _ in
            throw IMAPError.authFailed("auth error")
        })

        do {
            _ = try await harness.named.noop()
        } catch {
            // expected – authentication throws before any command reaches the server
        }

        let activity = await harness.named.lastActivity
        #expect(activity == nil)
        await harness.shutdown()
    }

    @Test
    func concurrentAuthenticationRequestsShareSingleInFlightAttempt() async throws {
        let gate = AuthenticationGate()
        let harness = makeConnection(authenticate: { connection in
            await gate.startAndWait()
            connection.isSessionAuthenticated = true
        })

        do {
            let first = Task {
                try await harness.named.ensureAuthenticated()
            }

            while await gate.startCount() < 1 {
                try await Task.sleep(nanoseconds: 1_000_000)
            }

            let second = Task {
                try await harness.named.ensureAuthenticated()
            }

            try await waitForAuthenticationWaiter(on: harness.named, gate: gate)
            #expect(await gate.startCount() == 1)

            await gate.releaseAll()
            try await first.value
            try await second.value
            await harness.shutdown()
        } catch {
            await gate.releaseAll()
            await harness.shutdown()
            throw error
        }
    }

    #if os(macOS)
        @Test
        func concurrentSameNameConnectionRequestsShareSingleHandle() async throws {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            let curDir = maildir.appendingPathComponent("cur")
            let newDir = maildir.appendingPathComponent("new")

            try FileManager.default.createDirectory(at: curDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempRoot)
            }

            let sampleMessage = """
            From: Test <sender@example.com>\r
            To: Test <recipient@example.com>\r
            Subject: Test\r
            Date: Thu, 01 Jan 2026 00:00:00 +0000\r
            Message-ID: <test@example.com>\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            Body.\r
            """
            try sampleMessage.data(using: .utf8)?.write(to: curDir.appendingPathComponent("1.eml"))

            let testServer = try IMAPTestServer(
                host: "localhost",
                port: 0,
                username: "u",
                password: "p",
                loginResponseDelay: 0.15,
                maildirURL: maildir
            )
            try testServer.start()
            defer { testServer.stop() }

            let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
            try await server.connect()
            try await server.login(username: "u", password: "p")

            async let first = server.connection(named: "shared")
            async let second = server.connection(named: "shared")
            let handles = try await (first, second)

            #expect(ObjectIdentifier(handles.0) == ObjectIdentifier(handles.1))
            try await server.disconnect()
        }
    #endif

    @Test
    func uidExpungeRequiresUIDPlusCapability() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let connection = IMAPConnection(
            host: "localhost",
            port: 1,
            useTLS: false,
            group: group,
            loggerLabel: "test.imap",
            outboundLabel: "test.imap.out",
            inboundLabel: "test.imap.in",
            connectionID: "test-uidexpunge",
            connectionRole: "test"
        )
        connection.replaceCapabilitiesForTesting([])
        let named = IMAPNamedConnection(name: "test", connection: connection, authenticateOnConnection: { _ in })

        do {
            try await named.expunge(messages: UIDSet(UID(7)))
            Issue.record("Expected UID EXPUNGE to require UIDPLUS")
        } catch let error as IMAPError {
            guard case .commandNotSupported(let message) = error else {
                Issue.record("Expected commandNotSupported, got \(error)")
                return
            }
            #expect(message == "UID EXPUNGE command not supported by server")
        } catch {
            Issue.record("Expected IMAPError.commandNotSupported, got \(error)")
        }
        try? await group.shutdownGracefully()
    }

    @Test
    func sortedSearchRequiresSortCapability() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let connection = IMAPConnection(
            host: "localhost",
            port: 1,
            useTLS: false,
            group: group,
            loggerLabel: "test.imap",
            outboundLabel: "test.imap.out",
            inboundLabel: "test.imap.in",
            connectionID: "test-sort-capability",
            connectionRole: "test"
        )
        connection.replaceCapabilitiesForTesting([])
        let named = IMAPNamedConnection(name: "test", connection: connection, authenticateOnConnection: { _ in })

        do {
            _ = try await named.extendedSearch(
                criteria: [.all],
                sortCriteria: [.descending(.date)]
            ) as ExtendedSearchResult<SwiftMail.UID>
            Issue.record("Expected SORT to require server support")
        } catch let error as IMAPError {
            guard case .commandNotSupported(let message) = error else {
                Issue.record("Expected commandNotSupported, got \(error)")
                return
            }
            #expect(message == "SORT command not supported by server")
        } catch {
            Issue.record("Expected IMAPError.commandNotSupported, got \(error)")
        }
        try? await group.shutdownGracefully()
    }
}
