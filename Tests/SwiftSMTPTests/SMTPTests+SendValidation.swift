import Foundation
@testable import SwiftMail
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SMTPSendValidationTests {
    // MARK: - sendRawMessage validation

    @Test
    func sendRawMessageRequiresAtLeastOneRecipient() async {
        let server = SMTPServer(host: "smtp.example.com", port: 587)
        let rawMessage = Data("Subject: Test\r\n\r\nBody".utf8)
        let sender = EmailAddress(address: "sender@example.com")

        await #expect(throws: SMTPError.self) {
            try await server.sendRawMessage(rawMessage, from: sender, to: [])
        }
    }

    @Test
    func sendRawMessageRequiresConnection() async {
        let server = SMTPServer(host: "smtp.example.com", port: 587)
        let rawMessage = Data("Subject: Test\r\n\r\nBody".utf8)
        let sender = EmailAddress(address: "sender@example.com")
        let recipient = EmailAddress(address: "recipient@example.com")

        await #expect(throws: SMTPError.self) {
            try await server.sendRawMessage(rawMessage, from: sender, to: [recipient])
        }
    }

    @Test
    func sendRawMessageRequiresConnectionBeforeValidation() async {
        let server = SMTPServer(host: "smtp.example.com", port: 587)
        // Data with 8-bit content
        let data8Bit = Data([0xFF, 0xFE, 0x00, 0x48, 0x65, 0x6C, 0x6C, 0x6F])
        let sender = EmailAddress(address: "sender@example.com")
        let recipient = EmailAddress(address: "recipient@example.com")

        // Should fail with connectionFailed (checked before 8BITMIME validation)
        do {
            try await server.sendRawMessage(data8Bit, from: sender, to: [recipient])
            Issue.record("Expected SMTPError to be thrown")
        } catch let error as SMTPError {
            // Verify it's a connection error, not an 8BITMIME error
            if case .connectionFailed = error {
                // Expected
            } else {
                Issue.record("Expected connectionFailed, got: \(error)")
            }
        } catch {
            Issue.record("Expected SMTPError, got: \(error)")
        }
    }

    @Test
    func sendRawMessage7BitContentDoesNotRequire8BitMIME() async {
        let server = SMTPServer(host: "smtp.example.com", port: 587)
        // Pure 7-bit ASCII content (all bytes <= 127)
        let data7Bit = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]) // "Hello"
        let sender = EmailAddress(address: "sender@example.com")
        let recipient = EmailAddress(address: "recipient@example.com")

        // Should fail with connectionFailed, NOT an 8BITMIME error
        // (because 7-bit content doesn't require 8BITMIME support)
        do {
            try await server.sendRawMessage(data7Bit, from: sender, to: [recipient])
            Issue.record("Expected SMTPError to be thrown")
        } catch let error as SMTPError {
            if case .connectionFailed = error {
                // Expected - would fail at connection, not 8BITMIME check
            } else {
                Issue.record("Expected connectionFailed for 7-bit content, got: \(error)")
            }
        } catch {
            Issue.record("Expected SMTPError, got: \(error)")
        }
    }
}
