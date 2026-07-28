import Foundation
import Testing
@testable import SwiftMail

#if os(macOS)
    @Suite(.serialized, .timeLimit(.minutes(1)))
    struct IMAPIdleGroupLifecycleTests {

        private func makeTestServer() throws -> (IMAPTestServer, URL) {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            let curDir = maildir.appendingPathComponent("cur")
            let newDir = maildir.appendingPathComponent("new")

            try FileManager.default.createDirectory(at: curDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)

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

            let server = try IMAPTestServer(
                host: "localhost",
                port: 0,
                username: "u",
                password: "p",
                maildirURL: maildir
            )
            return (server, tempRoot)
        }

        /// The idle connection must use its own EventLoopGroup, independent of the
        /// IMAPServer's group. Deallocating the server must not crash the idle session.
        @Test
        func idleSessionSurvivesServerDeallocation() async throws {
            let (testServer, tempRoot) = try makeTestServer()
            try testServer.start()
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            try await testServer.run {
                // Create server, start IDLE, then deallocate the server.
                var session: IMAPIdleSession?
                do {
                    let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                    try await server.connect()
                    try await server.login(username: "u", password: "p")
                    session = try await server.idle(on: "INBOX")
                    // server goes out of scope here — its deinit fires shutdownGracefully()
                }

                guard let session else {
                    Issue.record("Failed to create IDLE session")
                    return
                }

                // The session should still be usable after the server is deallocated.
                // Give the deinit's shutdown a moment to execute.
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

                // Ending the session should not crash (no "event loop shut down" assertion).
                try? await session.done()
            }
        }

        @Test
        func repeatedIdleRenewalsDoNotTripClientStateMachine() async throws {
            let (testServer, tempRoot) = try makeTestServer()
            try testServer.start()
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            try await testServer.run {
                let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()
                try await server.login(username: "u", password: "p")

                let configuration = IMAPIdleConfiguration(
                    renewalInterval: 0.05,
                    noopInterval: 1,
                    postIdleNoopEnabled: false,
                    postIdleNoopDelay: 0,
                    doneTimeout: 2,
                    reconnectBaseDelay: 0.01,
                    reconnectMaxDelay: 0.01,
                    reconnectJitterFactor: 0
                )
                let session = try await server.idle(on: "INBOX", configuration: configuration)

                try await Task.sleep(nanoseconds: 1_000_000_000)
                #expect(testServer.idleCommandCount >= 2)
                try await session.done()
                try? await server.disconnect()
            }
        }

        /// `server.disconnect()` must terminate a dedicated IDLE session for good.
        /// The cycle task is self-healing: closing the socket without stopping the
        /// task first makes it treat the close as a dropped connection and re-dial
        /// (the IMAP-side leak behind Cocoanetics/Post#30). After disconnect, the
        /// session's events stream must finish and the server must see no further
        /// IDLE commands.
        @Test
        func disconnectTerminatesDedicatedIdleSessionWithoutRedial() async throws {
            let (testServer, tempRoot) = try makeTestServer()
            try testServer.start()
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            try await testServer.run {
                let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()
                try await server.login(username: "u", password: "p")

                // Long renewal so the only thing that can grow idleCommandCount
                // after disconnect is a reconnect; near-instant reconnect delays so
                // a surviving cycle task would re-dial well inside the observation
                // window.
                let configuration = IMAPIdleConfiguration(
                    renewalInterval: 60,
                    noopInterval: 60,
                    postIdleNoopEnabled: false,
                    postIdleNoopDelay: 0,
                    doneTimeout: 2,
                    reconnectBaseDelay: 0.01,
                    reconnectMaxDelay: 0.05,
                    reconnectJitterFactor: 0
                )
                let session = try await server.idle(on: "INBOX", configuration: configuration)
                #expect(try await waitForIdleCommandCount(testServer, atLeast: 1))
                let idleCommandsBeforeDisconnect = testServer.idleCommandCount

                try await server.disconnect()

                #expect(
                    await waitForStreamFinish(session),
                    "events stream must finish after server.disconnect()"
                )

                // Ample window for a surviving runner to re-dial (its reconnect
                // delay is 10–50 ms).
                try await Task.sleep(nanoseconds: 500_000_000)
                #expect(testServer.idleCommandCount == idleCommandsBeforeDisconnect)

                // A redundant done() after disconnect must be safe and idempotent.
                try? await session.done()
            }
        }

        /// Consumers end IDLE producers with `try? await session.done()` from a
        /// task that is itself already cancelled (Cocoanetics/Post#30's watch
        /// loops do exactly this). Teardown must complete regardless: the events
        /// stream finishes and the runner does not survive to renew or re-dial.
        @Test
        func doneFromCancelledTaskStillTearsDownSession() async throws {
            let (testServer, tempRoot) = try makeTestServer()
            try testServer.start()
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            try await testServer.run {
                let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()
                try await server.login(username: "u", password: "p")

                let configuration = IMAPIdleConfiguration(
                    renewalInterval: 60,
                    noopInterval: 60,
                    postIdleNoopEnabled: false,
                    postIdleNoopDelay: 0,
                    doneTimeout: 2,
                    reconnectBaseDelay: 0.01,
                    reconnectMaxDelay: 0.05,
                    reconnectJitterFactor: 0
                )
                let session = try await server.idle(on: "INBOX", configuration: configuration)
                #expect(try await waitForIdleCommandCount(testServer, atLeast: 1))
                let idleCommandsBefore = testServer.idleCommandCount

                let doneTask = Task {
                    try? await session.done()
                }
                doneTask.cancel()
                await doneTask.value

                #expect(
                    await waitForStreamFinish(session),
                    "events stream must finish after done() from a cancelled task"
                )

                try await Task.sleep(nanoseconds: 500_000_000)
                #expect(testServer.idleCommandCount == idleCommandsBefore)

                try? await server.disconnect()
            }
        }

        private func waitForStreamFinish(
            _ session: IMAPIdleSession,
            timeoutNanoseconds: UInt64 = 5_000_000_000
        ) async -> Bool {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await _ in session.events {}
                    return true
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
        }

        private func waitForIdleCommandCount(
            _ testServer: IMAPTestServer,
            atLeast expected: Int,
            timeoutNanoseconds: UInt64 = 5_000_000_000
        ) async throws -> Bool {
            let start = DispatchTime.now().uptimeNanoseconds
            while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
                if testServer.idleCommandCount >= expected { return true }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return testServer.idleCommandCount >= expected
        }

        /// The idle group should be cleaned up when the initial connection fails.
        @Test
        func idleGroupCleanedUpOnConnectionFailure() async throws {
            let server = IMAPServer(host: "127.0.0.1", port: 1, useTLS: false)
            // Port 1 will refuse — idle(on:) should fail and clean up its group.
            do {
                _ = try await server.idle(on: "INBOX")
                Issue.record("Expected idle to throw on refused port")
            } catch {
                // Expected — the idle group should have been shut down in the catch path.
                // If not, the threads would leak but no crash. Success = no crash.
            }
            try? await server.disconnect()
        }
    }
#endif
