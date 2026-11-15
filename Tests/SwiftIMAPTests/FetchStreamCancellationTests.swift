#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct FetchStreamCancellationTests {
    enum Fetch: CaseIterable {
        case primaryMetadata, namedMetadata, primaryRaw, namedRaw, complete

        var isNamed: Bool { self == .namedMetadata || self == .namedRaw }
        var isMetadata: Bool { self == .primaryMetadata || self == .namedMetadata }
    }

    @Test(arguments: Fetch.allCases, [false, true])
    func consumerCancellationAndAbortCloseHeldFetch(fetch: Fetch, abort: Bool) async throws {
        try await withFixture(scripts: scripts(for: fetch)) { fixture, client, named, connection in
            let received = IMAPTestCounter()
            let consumer = Task { try await consume(fetch, client: client, named: named, received: received) }
            defer { consumer.cancel() }
            let held = try await fixture.waitForEvent(.replyHeld, run: fixture.runID, detail: "fetch")
            try await authenticationWaitUntil { received.value == 1 }
            let commands = fixture.commandLines(on: held.connection)
            #expect(commands.last?.contains(fetch.isMetadata ? "UID FETCH 2" : "BODY.PEEK[") == true)

            if abort {
                if fetch.isNamed { await named.abort() } else { await client.abort() }
                await #expect(throws: IMAPConnectionAbortedError.self) {
                    try await authenticationResult(consumer)
                }
            } else {
                consumer.cancel()
                // AsyncThrowingStream may finish normally when its waiting task
                // is cancelled; the producer must still cancel the wire command.
                do { try await authenticationResult(consumer) } catch is CancellationError {}
            }

            _ = try await fixture.waitForEvent(.peerEOF, run: fixture.runID, connection: held.connection)
            #expect(!fixture.release(try #require(held.command), gate: "fetch"))
            #expect(received.value == 1)
            #expect(fixture.commandLines(on: held.connection) == commands)
            try await authenticationWaitUntil { connection.lifetime.reservationCount == 0 }

            // A replacement transport must not revive the terminated producer.
            if fetch.isNamed { try await named.connect() } else { try await client.connect() }
            _ = try await connection.noop()
            let replacement = fixture.commandLines(on: fixture.connection(2))
            #expect(replacement.count == 2)
            #expect(replacement.last?.contains(" NOOP") == true)
            #expect(!replacement.contains { $0.contains("FETCH") })
            #expect(received.value == 1)
        }
    }

    @Test(arguments: Fetch.allCases)
    func queuedConsumerCancellationPreservesOwner(fetch: Fetch) async throws {
        let script = IMAPTestServer.Script(connectionNumber: 1, occurrence: 2, actions: [
            .hold("owner"), .taggedCompletion("OK NOOP completed")
        ])
        try await withFixture(scripts: [script]) { fixture, client, named, connection in
            let owner = Task { try await connection.noop() }
            defer { owner.cancel() }
            let held = try await fixture.waitForEvent(.replyHeld, run: fixture.runID, detail: "owner")
            let queued = IMAPTestSignal()
            connection.commandQueue.testHooks.didEnqueue = queued.signal
            let received = IMAPTestCounter()
            let consumer = Task { try await consume(fetch, client: client, named: named, received: received) }
            defer { consumer.cancel() }
            try await authenticationResult(Task { await queued.wait() })
            consumer.cancel()
            do { try await authenticationResult(consumer) } catch is CancellationError {}
            try await authenticationWaitUntil { connection.lifetime.reservationCount == 1 }
            #expect(connection.isConnected)
            #expect(received.value == 0)
            #expect(fixture.commandLines(on: held.connection).count == 2)
            #expect(fixture.release(try #require(held.command), gate: "owner"))
            _ = try await authenticationResult(owner)
            _ = try await connection.noop()
            #expect(connection.isConnected)
            #expect(!fixture.events.contains { $0.kind == .peerEOF })
            #expect(!fixture.commandLines(on: held.connection).contains { $0.contains("FETCH") })
        }
    }

    enum FallbackOutcome: CaseIterable { case cancel, abort, refusal }

    @Test(arguments: [false, true], FallbackOutcome.allCases)
    func structureMIMEHeaderFallbackPreservesTerminalErrors(namedTarget: Bool, outcome: FallbackOutcome) async throws {
        let structure = "* 1 FETCH (UID 1 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" NIL NIL NIL \"7BIT\" 3 1)"
            + "(\"APPLICATION\" \"OCTET-STREAM\" (\"NAME\" \"file.txt\") NIL NIL \"7BIT\" 3 "
            + "NIL (\"ATTACHMENT\" (\"FILENAME\" \"file.txt\")) NIL NIL) \"MIXED\"))\r\n"
        let scripts = [
            reply(2, structure),
            IMAPTestServer.Script(connectionNumber: 1, occurrence: 3, actions: [
                .hold("mime"), .taggedCompletion("NO MIME headers unavailable")
            ])
        ]
        try await withFixture(scripts: scripts) { fixture, client, named, _ in
            let fetch = Task {
                if namedTarget { return try await named.fetchStructure(SwiftMail.UID(1)) }
                return try await client.fetchStructure(SwiftMail.UID(1))
            }
            defer { fetch.cancel() }
            let held = try await fixture.waitForEvent(.replyHeld, run: fixture.runID, detail: "mime")
            #expect(fixture.commandLog.last?.contains("BODY.PEEK[2.MIME]") == true)
            switch outcome {
                case .cancel:
                    fetch.cancel()
                    await #expect(throws: CancellationError.self) { try await authenticationResult(fetch) }
                case .abort:
                    if namedTarget { await named.abort() } else { await client.abort() }
                    await #expect(throws: IMAPConnectionAbortedError.self) { try await authenticationResult(fetch) }
                case .refusal:
                    #expect(fixture.release(try #require(held.command), gate: "mime"))
                    let parts = try await authenticationResult(fetch)
                    #expect(parts.map(\.filename) == [nil, "file.txt"])
            }
            if outcome != .refusal {
                _ = try await fixture.waitForEvent(.peerEOF, run: fixture.runID, connection: held.connection)
                #expect(!fixture.release(try #require(held.command), gate: "mime"))
            }
            #expect(fixture.commandLog.count == 3)
        }
    }

    private func consume(
        _ fetch: Fetch, client: IMAPServer, named: IMAPNamedConnection, received: IMAPTestCounter
    ) async throws {
        let identifiers = SwiftMail.UIDSet(SwiftMail.UID(1)...SwiftMail.UID(3))
        switch fetch {
            case .primaryMetadata, .namedMetadata:
                let stream = fetch.isNamed
                    ? named.fetchMessageInfos(using: identifiers, options: .uidFlagsOnly, chunkSize: 1)
                    : client.fetchMessageInfos(using: identifiers, options: .uidFlagsOnly, chunkSize: 1)
                for try await info in stream {
                    #expect(info.uid == SwiftMail.UID(1))
                    _ = received.increment()
                }
            case .primaryRaw, .namedRaw:
                let stream = fetch.isNamed
                    ? named.fetchRawMessages(using: identifiers, chunkSize: 1)
                    : client.fetchRawMessages(using: identifiers, chunkSize: 1)
                for try await (uid, data) in stream {
                    #expect(uid == SwiftMail.UID(1))
                    #expect(data == Data("abc".utf8))
                    _ = received.increment()
                }
            case .complete:
                for try await message in client.fetchMessages(using: identifiers) {
                    #expect(message.parts.map(\.data) == [Data("abc".utf8)])
                    _ = received.increment()
                }
        }
    }

    private func reply(_ occurrence: Int, _ response: String) -> IMAPTestServer.Script {
        IMAPTestServer.Script(connectionNumber: 1, occurrence: occurrence, actions: [
            .send(Data(response.utf8), acknowledgement: "response"), .taggedCompletion("OK FETCH completed")
        ])
    }

    private func scripts(for fetch: Fetch) -> [IMAPTestServer.Script] {
        if fetch.isMetadata {
            return [reply(2, "* 1 FETCH (UID 1 FLAGS ())\r\n"),
                    IMAPTestServer.Script(connectionNumber: 1, occurrence: 3, actions: [
                        .hold("fetch"), .taggedCompletion("OK FETCH completed")
                    ])]
        }
        if fetch != .complete {
            return [reply(2, "* 1 FETCH (UID 1 BODY[] {3}\r\nabc)\r\n"), heldLiteral(3, section: "")]
        }
        let textPart = "(\"TEXT\" \"PLAIN\" (\"CHARSET\" \"utf-8\") NIL NIL \"7BIT\" 3 1)"
        return [
            reply(2, "* 1 FETCH (UID 1 FLAGS ())\r\n* 2 FETCH (UID 2 FLAGS ())\r\n"),
            reply(3, "* 1 FETCH (UID 1 BODYSTRUCTURE \(textPart))\r\n"),
            reply(4, "* 1 FETCH (UID 1 BODY[1] {3}\r\nabc)\r\n"),
            reply(5, "* 2 FETCH (UID 2 BODYSTRUCTURE (\(textPart)\(textPart) \"MIXED\"))\r\n"),
            heldLiteral(6, section: "1")
        ]
    }

    private func heldLiteral(_ occurrence: Int, section: String) -> IMAPTestServer.Script {
        IMAPTestServer.Script(connectionNumber: 1, occurrence: occurrence, actions: [
            .send(Data("* 2 FETCH (UID 2 BODY[\(section)] {6}\r\nabc".utf8), acknowledgement: "partial-literal"),
            .hold("fetch"), .send(Data("def)\r\n".utf8), acknowledgement: "remaining-literal"),
            .taggedCompletion("OK FETCH completed")
        ])
    }

    private func withFixture(
        scripts: [IMAPTestServer.Script],
        _ body: (IMAPTestServer, IMAPServer, IMAPNamedConnection, IMAPConnection) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cur"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("new"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try IMAPTestServer(scripts: scripts, maildirURL: root)
        try fixture.start()
        try await fixture.run {
            let client = IMAPServer(host: "127.0.0.1", port: fixture.port, useTLS: false)
            try await client.connect()
            let connection = await client.primaryConnection
            // Bootstrap/authentication is covered elsewhere. Exercise both public
            // FETCH facades over the same real decoder and gated socket setup.
            connection.markSessionAuthenticated()
            let named = IMAPNamedConnection(name: "fetch", connection: connection,
                                            authenticateOnConnection: { $0.markSessionAuthenticated() })
            do {
                try await body(fixture, client, named, connection)
                try await client.disconnect()
            } catch {
                try? await client.disconnect()
                throw error
            }
        }
        #expect(fixture.fixtureFailures.isEmpty)
    }
}
#endif
