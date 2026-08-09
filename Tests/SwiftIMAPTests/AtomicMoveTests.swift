import Foundation
import NIOIMAPCore
import Testing
@testable import SwiftMail

#if os(macOS)
    @Suite("MOVE fallback policy", .serialized, .timeLimit(.minutes(1)))
    struct AtomicMoveTests {
        @Test("Default policy uses MOVE with UIDPLUS")
        func defaultPolicyUsesMoveWithUIDPlus() async throws {
            try await withServer(capabilities: ["IMAP4rev1", "AUTH=PLAIN", "MOVE", "UIDPLUS"]) { server, testServer in
                let result = try await server.move(messages: UIDSet(UID(1)), to: "Archive")
                let copyUID = try #require(result)
                #expect(copyUID.destinationUIDValidity == UIDValidity(2))
                #expect(copyUID.mapping.map(\.source.value) == [1])
                #expect(copyUID.mapping.map(\.destination.value) == [101])
                assertOnlyAtomicMoveWasEmitted(testServer.commandLog)
            }
        }

        @Test("Disabled fallback uses MOVE without UIDPLUS")
        func disabledFallbackUsesMoveWithoutUIDPlus() async throws {
            try await withServer(capabilities: ["IMAP4rev1", "AUTH=PLAIN", "MOVE"]) { server, testServer in
                let result = try await server.move(
                    messages: UIDSet(UID(1)), to: "Archive", fallback: .disabled)
                #expect(result == nil)
                assertOnlyAtomicMoveWasEmitted(testServer.commandLog)
            }
        }

        @Test("Default policy preserves COPY STORE EXPUNGE fallback")
        func defaultPolicyPreservesExistingFallback() async throws {
            try await withServer(capabilities: ["IMAP4rev1", "AUTH=PLAIN", "MOVE"]) { server, testServer in
                let result = try await server.move(messages: UIDSet(UID(1)), to: "Archive")

                #expect(result == nil)
                assertOnlyFallbackWasEmitted(testServer.commandLog)
            }
        }

        @Test("Named single-message convenience forwards disabled fallback")
        func namedConnectionForwardsDisabledFallback() async throws {
            try await withServer(capabilities: ["IMAP4rev1", "AUTH=PLAIN", "MOVE"]) { server, testServer in
                let named = try await server.connection(named: "atomic-move")
                _ = try await named.selectMailbox("INBOX")

                let result = try await named.move(
                    message: UID(1), to: "Archive", fallback: .disabled)

                #expect(result == nil)
                assertOnlyAtomicMoveWasEmitted(testServer.commandLog)
            }
        }

        @Test("Header convenience forwards disabled fallback")
        func headerConvenienceForwardsDisabledFallback() async throws {
            try await withServer(capabilities: ["IMAP4rev1", "AUTH=PLAIN", "MOVE"]) { server, testServer in
                let header = MessageInfo(sequenceNumber: SequenceNumber(1), uid: UID(1))
                let result = try await server.move(
                    header: header, to: "Archive", fallback: .disabled)

                #expect(result == nil)
                assertOnlyAtomicMoveWasEmitted(testServer.commandLog)
            }
        }

        @Test("Disabled fallback without MOVE refuses before any transport command")
        func noMoveRefusesBeforeTransport() async {
            let server = SwiftMail.IMAPServer(host: "127.0.0.1", port: 1, useTLS: false)
            await server.primaryConnection.replaceCapabilitiesForTesting([])
            do {
                _ = try await server.move(
                    messages: UIDSet(UID(1)), to: "Archive", fallback: .disabled)
                Issue.record("Expected commandNotSupported")
            } catch let error as IMAPError {
                guard case .commandNotSupported = error else {
                    Issue.record("Expected commandNotSupported, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected IMAPError.commandNotSupported, got \(error)")
            }
        }

        @Test(
            "Parser-produced MOVE spellings work on server and named connection",
            arguments: ["MOVE", "move", "MoVe"]
        )
        func parserProducedMoveSpelling(_ spelling: String) async throws {
            try await withServer(capabilities: ["IMAP4rev1", "AUTH=PLAIN", spelling]) { server, testServer in
                #expect(await server.supportsMove)
                _ = try await server.move(
                    messages: UIDSet(UID(1)), to: "Archive", fallback: .disabled)

                let named = try await server.connection(named: "case-insensitive-move")
                #expect(await named.supportsMove)
                _ = try await named.selectMailbox("INBOX")
                _ = try await named.move(
                    messages: UIDSet(UID(1)), to: "Archive", fallback: .disabled)

                assertOnlyMovesWereEmitted(testServer.commandLog, count: 2)
            }
        }

        private func withServer(
            capabilities: [String],
            body: (SwiftMail.IMAPServer, IMAPTestServer) async throws -> Void
        ) async throws {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            let curDir = maildir.appendingPathComponent("cur")
            try FileManager.default.createDirectory(at: curDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let sample = """
            From: Sender <sender@example.com>\r
            To: Recipient <recipient@example.com>\r
            Subject: Atomic move\r
            Date: Wed, 01 Jan 2020 00:00:00 +0000\r
            Message-ID: <atomic@example.com>\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            Body.\r
            """
            try #require(sample.data(using: .utf8)).write(to: curDir.appendingPathComponent("1.eml"))

            let testServer = try IMAPTestServer(
                username: "u", password: "p", advertisedCapabilities: capabilities,
                maildirURL: maildir)
            try testServer.start()
            try await testServer.run {
                let server = SwiftMail.IMAPServer(
                    host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()
                try await server.login(username: "u", password: "p")
                _ = try await server.selectMailbox("INBOX")
                try await body(server, testServer)
                try await server.disconnect()
            }
        }

        private func assertOnlyAtomicMoveWasEmitted(_ commands: [String]) {
            assertOnlyMovesWereEmitted(commands, count: 1)
        }

        private func assertOnlyMovesWereEmitted(_ commands: [String], count: Int) {
            let upper = commands.map { $0.uppercased() }
            #expect(upper.filter { $0.contains(" UID MOVE ") }.count == count)
            #expect(upper.allSatisfy { !$0.contains(" UID COPY ") })
            #expect(upper.allSatisfy { !$0.contains(" UID STORE ") })
            #expect(upper.allSatisfy { !$0.contains("UID EXPUNGE") })
            #expect(upper.allSatisfy { !$0.contains(" EXPUNGE") })
        }

        private func assertOnlyFallbackWasEmitted(_ commands: [String]) {
            let upper = commands.map { $0.uppercased() }
            #expect(upper.allSatisfy { !$0.contains(" UID MOVE ") })
            #expect(upper.filter { $0.contains(" UID COPY ") }.count == 1)
            #expect(upper.filter { $0.contains(" UID STORE ") }.count == 1)
            #expect(upper.filter { $0.contains(" EXPUNGE") }.count == 1)
        }
    }
#endif
