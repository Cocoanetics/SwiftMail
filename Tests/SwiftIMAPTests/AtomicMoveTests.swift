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

        @Test("Original MOVE overloads remain usable as function values")
        func originalMoveOverloadsRemainFunctionValues() async throws {
            try await withServer(
                capabilities: ["IMAP4rev1", "AUTH=PLAIN", "MOVE", "UIDPLUS"]
            ) { server, _ in
                let named = try await server.connection(named: "function-values")

                let serverMessages: (SwiftMail.UIDSet, String) async throws -> CopyUID? =
                    server.move(messages:to:)
                let serverMessage: (SwiftMail.UID, String) async throws -> CopyUID? =
                    server.move(message:to:)
                let serverHeader: (MessageInfo, String) async throws -> CopyUID? =
                    server.move(header:to:)
                let namedMessages: (SwiftMail.UIDSet, String) async throws -> CopyUID? =
                    named.move(messages:to:)
                let namedMessage: (SwiftMail.UID, String) async throws -> CopyUID? =
                    named.move(message:to:)

                _ = (serverMessages, serverMessage, serverHeader, namedMessages, namedMessage)
            }
        }

        @Test("MOVE capability is checked after server and named reauthentication")
        func moveCapabilityIsCheckedAfterReauthentication() async throws {
            try await withServer(
                capabilities: ["IMAP4rev1", "AUTH=PLAIN", "MOVE"]
            ) { server, testServer in
                let named = try await server.connection(named: "reauthenticated-move")
                _ = try await named.selectMailbox("INBOX")

                try await server.primaryConnection.disconnect()
                try await named.disconnect()

                await expectMoveAttemptAfterReauthentication {
                    try await server.move(
                        messages: UIDSet(UID(1)),
                        to: "Archive",
                        fallback: .disabled
                    )
                }
                await expectMoveAttemptAfterReauthentication {
                    try await named.move(
                        messages: UIDSet(UID(1)),
                        to: "Archive",
                        fallback: .disabled
                    )
                }

                let moveCommands = testServer.commandLog
                    .map { $0.uppercased() }
                    .filter { $0.contains(" UID MOVE ") }
                #expect(moveCommands.count == 2)
            }
        }

        private func withServer(
            capabilities: [String],
            rejectedUIDSubcommand: String? = nil,
            copyUIDSourceOverride: String? = nil,
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
                username: "u", password: "p",
                rejectedUIDSubcommand: rejectedUIDSubcommand,
                copyUIDSourceOverride: copyUIDSourceOverride,
                advertisedCapabilities: capabilities,
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

        private func expectMoveAttemptAfterReauthentication(
            _ operation: () async throws -> CopyUID?
        ) async {
            do {
                _ = try await operation()
                Issue.record("Expected MOVE to report possible partial completion")
            } catch let error as IMAPError {
                guard case .moveFailedAfterPossiblePartialCompletion = error else {
                    Issue.record("Expected possible partial completion after authenticated MOVE, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected IMAPError.moveFailedAfterPossiblePartialCompletion, got \(error)")
            }
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

    extension AtomicMoveTests {
        @Test("Lowercase UIDPLUS keeps UID MOVE atomic on both connection surfaces")
        func lowercaseUIDPlusUsesMove() async throws {
            try await withServer(
                capabilities: ["IMAP4rev1", "AUTH=PLAIN", "move", "uidplus"]
            ) { server, testServer in
                #expect(await server.supportsUIDPlus)
                _ = try await server.move(messages: UIDSet(UID(1)), to: "Archive")

                let named = try await server.connection(named: "lowercase-uidplus-move")
                #expect(await named.supportsUIDPlus)
                _ = try await named.selectMailbox("INBOX")
                _ = try await named.move(messages: UIDSet(UID(1)), to: "Archive")

                assertOnlyMovesWereEmitted(testServer.commandLog, count: 2)
            }
        }

        @Test("Lowercase UIDPLUS fallback uses targeted UID EXPUNGE")
        func lowercaseUIDPlusUsesTargetedFallbackExpunge() async throws {
            try await withServer(
                capabilities: ["IMAP4rev1", "AUTH=PLAIN", "uidplus"]
            ) { server, testServer in
                _ = try await server.move(messages: UIDSet(UID(1)), to: "Archive")

                let named = try await server.connection(named: "lowercase-uidplus-fallback")
                _ = try await named.selectMailbox("INBOX")
                _ = try await named.move(messages: UIDSet(UID(1)), to: "Archive")

                let upper = testServer.commandLog.map { $0.uppercased() }
                #expect(upper.filter { $0.contains(" UID COPY ") }.count == 2)
                #expect(upper.filter { $0.contains(" UID STORE ") }.count == 2)
                #expect(upper.filter { $0.contains(" UID EXPUNGE ") }.count == 2)
                #expect(upper.allSatisfy { !$0.contains(" EXPUNGE") || $0.contains(" UID EXPUNGE ") })
            }
        }

        @Test("Fallback failure preserves COPYUID on server and named connection")
        func fallbackFailurePreservesCopyUID() async throws {
            try await withServer(
                capabilities: ["IMAP4rev1", "AUTH=PLAIN", "UIDPLUS"],
                rejectedUIDSubcommand: "STORE"
            ) { server, _ in
                await expectVerifiedPartialFailure {
                    try await server.move(messages: UIDSet(UID(1)), to: "Archive")
                }

                let named = try await server.connection(named: "partial-fallback")
                _ = try await named.selectMailbox("INBOX")
                await expectVerifiedPartialFailure {
                    try await named.move(messages: UIDSet(UID(1)), to: "Archive")
                }
            }
        }

        @Test("Fallback failure without COPYUID is non-retryable")
        func fallbackFailureWithoutCopyUIDIsNonRetryable() async throws {
            try await withServer(
                capabilities: ["IMAP4rev1", "AUTH=PLAIN"],
                rejectedUIDSubcommand: "STORE"
            ) { server, _ in
                await expectPossiblePartialFailure {
                    try await server.move(messages: UIDSet(UID(1)), to: "Archive")
                }
            }
        }

        @Test("COPYUID rejects source UIDs outside the requested command set")
        func copyUIDRejectsUnrequestedSourceUIDs() async throws {
            try await withServer(
                capabilities: ["IMAP4rev1", "AUTH=PLAIN", "MOVE", "UIDPLUS"],
                copyUIDSourceOverride: "2"
            ) { server, _ in
                await expectMalformedCompletion {
                    try await server.copy(messages: UIDSet(UID(1)), to: "Archive")
                }

                let named = try await server.connection(named: "unrequested-copyuid")
                _ = try await named.selectMailbox("INBOX")
                await expectMalformedCompletion {
                    try await named.move(
                        messages: UIDSet(UID(1)),
                        to: "Archive",
                        fallback: .disabled
                    )
                }
            }
        }

        private func expectVerifiedPartialFailure(
            _ operation: () async throws -> CopyUID?
        ) async {
            do {
                _ = try await operation()
                Issue.record("Expected moveFallbackFailedAfterCopy")
            } catch let error as IMAPError {
                guard case .moveFallbackFailedAfterCopy(let copyUID, let reason) = error else {
                    Issue.record("Expected verified fallback copy, got \(error)")
                    return
                }
                #expect(copyUID.mapping.map(\.source.value) == [1])
                #expect(copyUID.mapping.map(\.destination.value) == [101])
                #expect(reason.contains("COPY completed before fallback failed"))
            } catch {
                Issue.record("Expected IMAPError.moveFallbackFailedAfterCopy, got \(error)")
            }
        }

        private func expectPossiblePartialFailure(
            _ operation: () async throws -> CopyUID?
        ) async {
            do {
                _ = try await operation()
                Issue.record("Expected moveFailedAfterPossiblePartialCompletion")
            } catch let error as IMAPError {
                guard case .moveFailedAfterPossiblePartialCompletion = error else {
                    Issue.record("Expected possible partial completion, got \(error)")
                    return
                }
                #expect(error.recoverySuggestion?.contains("Do not retry") == true)
            } catch {
                Issue.record("Expected possible-partial IMAPError, got \(error)")
            }
        }

        private func expectMalformedCompletion(
            _ operation: () async throws -> CopyUID?
        ) async {
            do {
                _ = try await operation()
                Issue.record("Expected malformedCopyUIDAfterTaggedOK")
            } catch let error as IMAPError {
                guard case .malformedCopyUIDAfterTaggedOK = error else {
                    Issue.record("Expected malformed completion, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected malformed COPYUID IMAPError, got \(error)")
            }
        }
    }
#endif
