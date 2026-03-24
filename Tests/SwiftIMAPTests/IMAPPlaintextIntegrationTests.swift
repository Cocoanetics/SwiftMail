import Foundation
import Testing
@testable import SwiftMail

#if os(macOS)
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IMAPPlaintextIntegrationTests {
    @Test(.timeLimit(.minutes(1)))
    func connectsToPlaintextIMAPServer() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let maildir = tempRoot.appendingPathComponent("Maildir")
        let curDir = maildir.appendingPathComponent("cur")
        let newDir = maildir.appendingPathComponent("new")
        
        try FileManager.default.createDirectory(at: curDir, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true, attributes: nil)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        
        let sampleMessage = """
        From: Test Sender <sender@example.com>\r
        To: Test Recipient <recipient@example.com>\r
        Subject: Integration Test\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <test@example.com>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Hello from IMAP integration test.\r
        """
        let messageURL = curDir.appendingPathComponent("1.eml")
        try sampleMessage.data(using: .utf8)?.write(to: messageURL)
        
        let testServer = try IMAPTestServer(
            host: "localhost",
            port: 0,
            username: "testuser",
            password: "testpass",
            maildirURL: maildir
        )
        try testServer.start()
        defer { testServer.stop() }
        
        let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
        try await server.connect()
        try await server.login(username: "testuser", password: "testpass")
        let status = try await server.selectMailbox("INBOX")
        #expect(status.messageCount == 1)
        try await server.disconnect()
    }
}
#endif
