import Foundation
import Testing
@testable import SwiftMail

@Suite("Fetch Raw Message Command")
struct FetchRawMessageCommandTests {
    @Test("the timeout defaults to 10 seconds, can be raised and must be positive")
    func timeoutIsConfigurableAndValidated() throws {
        #expect(FetchRawMessageCommand(identifier: UID(1)).timeoutSeconds == 10)
        #expect(FetchRawMessageCommand(identifier: UID(1), timeoutSeconds: nil).timeoutSeconds == 10)
        let raised = FetchRawMessageCommand(identifier: UID(1), timeoutSeconds: 120)
        #expect(raised.timeoutSeconds == 120)
        try raised.validate()

        for invalid in [0, -1] {
            #expect(throws: IMAPError.self) {
                try FetchRawMessageCommand(identifier: UID(1), timeoutSeconds: invalid).validate()
            }
        }
    }
}

#if os(macOS)
    @Suite("Fetch Raw Message", .serialized, .timeLimit(.minutes(1)))
    struct FetchRawMessageTests {
        @Test("fetchRawMessage returns exact RFC 822 bytes from server")
        func fetchRawMessageRoundTripsExactBytes() async throws {
            let sampleMessage = Data(("""
            Return-Path: <sender@example.com>\r
            Received: from mx.example.com by inbox.example.com; Thu, 01 Jan 2026 00:00:00 +0000\r
            From: Test Sender <sender@example.com>\r
            To: Test Recipient <recipient@example.com>\r
            Subject: Raw fetch test\r
            Date: Thu, 01 Jan 2026 00:00:00 +0000\r
            Message-ID: <raw-fetch@example.com>\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            Hello from raw fetch.\r
            """).utf8)

            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            let curDir = maildir.appendingPathComponent("cur")
            let newDir = maildir.appendingPathComponent("new")

            try FileManager.default.createDirectory(at: curDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            try sampleMessage.write(to: curDir.appendingPathComponent("1.eml"))

            let testServer = try IMAPTestServer(
                host: "localhost",
                port: 0,
                username: "testuser",
                password: "testpass",
                maildirURL: maildir
            )
            try testServer.start()

            try await testServer.run {
                let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()

                try await server.login(username: "testuser", password: "testpass")
                _ = try await server.selectMailbox("INBOX")

                let raw = try await server.fetchRawMessage(identifier: UID(1))
                #expect(raw == sampleMessage)
                #expect(String(data: raw, encoding: .utf8)?.contains("Received: from mx.example.com") == true)

                let withTimeout = try await server.fetchRawMessage(identifier: UID(1), timeoutSeconds: 60)
                #expect(withTimeout == sampleMessage)

                try await server.disconnect()
            }
        }
    }
#endif
