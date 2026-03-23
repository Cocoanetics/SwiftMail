import Foundation
import Testing
@testable import SwiftMail

#if os(macOS)
struct IMAPPlaintextIntegrationTests {
    @Test(.disabled("Requires local Python IMAP server — run manually"))
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
        From: Test Sender <sender@example.com>
        To: Test Recipient <recipient@example.com>
        Subject: Integration Test
        Date: Thu, 01 Jan 2026 00:00:00 +0000
        Message-ID: <test@example.com>
        Content-Type: text/plain; charset=utf-8
        
        Hello from IMAP integration test.
        """
        let messageURL = curDir.appendingPathComponent("1.eml")
        try sampleMessage.data(using: .utf8)?.write(to: messageURL)
        
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/SwiftIMAPTests/Resources/imap_server.py")
        #expect(FileManager.default.fileExists(atPath: scriptURL.path))
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3",
            scriptURL.path,
            "--port", "0",
            "--maildir", maildir.path,
            "--user", "testuser",
            "--password", "testpass"
        ]
        
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        
        guard let readyLine = readLineBlocking(from: stdout.fileHandleForReading),
              readyLine.hasPrefix("READY:"),
              let port = Int(readyLine.replacingOccurrences(of: "READY:", with: "")) else {
            Issue.record("Failed to parse READY line from test IMAP server")
            return
        }
        
        let server = IMAPServer(host: "127.0.0.1", port: port, useTLS: false)
        try await server.connect()
        try await server.login(username: "testuser", password: "testpass")
        let status = try await server.selectMailbox("INBOX")
        #expect(status.messageCount == 1)
        try await server.disconnect()
    }
    
    private func readLineBlocking(from handle: FileHandle) -> String? {
        var buffer = Data()
        while true {
            let data = handle.readData(ofLength: 1)
            if data.isEmpty {
                return nil
            }
            if data == Data([0x0A]) {
                break
            }
            buffer.append(data)
        }
        return String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
