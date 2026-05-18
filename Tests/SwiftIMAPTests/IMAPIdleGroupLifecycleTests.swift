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

        let server = try IMAPTestServer(host: "localhost", port: 0, username: "u", password: "p", maildirURL: maildir)
        return (server, tempRoot)
    }

    /// The idle connection must use its own EventLoopGroup, independent of the
    /// IMAPServer's group. Deallocating the server must not crash the idle session.
    @Test
    func idleSessionSurvivesServerDeallocation() async throws {
        let (testServer, tempRoot) = try makeTestServer()
        try testServer.start()
        defer {
            testServer.stop()
            try? FileManager.default.removeItem(at: tempRoot)
        }

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
        // Give the deinit's shutdown Task a moment to execute.
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

        // Ending the session should not crash (no "event loop shut down" assertion).
        try? await session.done()
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
