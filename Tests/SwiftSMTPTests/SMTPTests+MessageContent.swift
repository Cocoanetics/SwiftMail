import Foundation
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SMTPMessageContentTests {
    @Test
    func testConstructContentAutoGeneratesMessageId() {
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Test",
            textBody: "Hello"
        )

        let content = email.constructContent()
        #expect(content.contains("Message-Id: <"))
        #expect(content.contains("@example.com>"))
    }

    @Test
    func testConstructContentUsesPresetMessageId() {
        let preset = MessageID(localPart: "my-custom-id", domain: "example.com")
        var email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Test",
            textBody: "Hello"
        )
        email.messageID = preset

        let content = email.constructContent()
        #expect(content.contains("Message-Id: <my-custom-id@example.com>\r\n"))

        // Should NOT contain a second auto-generated Message-Id
        let occurrences = content.components(separatedBy: "Message-Id:").count - 1
        #expect(occurrences == 1)
    }

    @Test
    func testConstructContentStableMessageIdAcrossCalls() {
        let preset = MessageID(localPart: "stable-id", domain: "example.com")
        var email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Test",
            textBody: "Hello"
        )
        email.messageID = preset

        let content1 = email.constructContent()
        let content2 = email.constructContent()

        // With a preset ID, both calls produce the same Message-Id
        #expect(content1.contains("Message-Id: <stable-id@example.com>"))
        #expect(content2.contains("Message-Id: <stable-id@example.com>"))
    }

    @Test
    func testMessageIdPropertyDoesNotAffectAdditionalHeaders() {
        var email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Test",
            textBody: "Hello"
        )
        email.messageID = MessageID(localPart: "preset", domain: "example.com")
        email.additionalHeaders = ["X-Custom": "value"]

        let content = email.constructContent()
        #expect(content.contains("Message-Id: <preset@example.com>"))
        #expect(content.contains("X-Custom: value"))

        // Only one Message-Id header
        let occurrences = content.components(separatedBy: "Message-Id:").count - 1
        #expect(occurrences == 1)
    }

    @Test
    func testConstructContentUsesAdditionalHeaderMessageIDExactlyOnce() {
        var email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Hello",
            textBody: "Body"
        )
        email.additionalHeaders = [
            "Message-ID": "<provided@example.com>",
            "X-Test-Header": "present"
        ]

        let content = email.constructContent()
        let messageIDHeaders = content
            .components(separatedBy: "\r\n")
            .filter { $0.lowercased().hasPrefix("message-id:") }

        #expect(messageIDHeaders.count == 1)
        #expect(messageIDHeaders.first == "Message-Id: <provided@example.com>")
        #expect(content.contains("X-Test-Header: present"))
    }

    @Test
    func testConstructContentTreatsAdditionalHeaderMessageIDCaseInsensitively() {
        var email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Hello",
            textBody: "Body"
        )
        email.additionalHeaders = ["message-id": "<lowercase@example.com>"]

        let content = email.constructContent()
        let messageIDHeaders = content
            .components(separatedBy: "\r\n")
            .filter { $0.lowercased().hasPrefix("message-id:") }

        #expect(messageIDHeaders.count == 1)
        #expect(messageIDHeaders.first == "Message-Id: <lowercase@example.com>")
    }

    @Test
    func testConstructContentMessageIDPropertyWinsOverAdditionalHeaderMessageID() {
        var email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Hello",
            textBody: "Body"
        )
        email.messageID = MessageID(localPart: "typed", domain: "example.com")
        email.additionalHeaders = ["Message-ID": "<raw@example.com>"]

        let content = email.constructContent()
        let messageIDHeaders = content
            .components(separatedBy: "\r\n")
            .filter { $0.lowercased().hasPrefix("message-id:") }

        #expect(messageIDHeaders.count == 1)
        #expect(messageIDHeaders.first == "Message-Id: <typed@example.com>")
    }

    @Test
    func testConstructContentPreservesRawAdditionalHeaderMessageIDWhenUnparseable() {
        var email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Hello",
            textBody: "Body"
        )
        email.additionalHeaders = ["Message-ID": "not a valid message id"]

        let content = email.constructContent()
        let messageIDHeaders = content
            .components(separatedBy: "\r\n")
            .filter { $0.lowercased().hasPrefix("message-id:") }

        #expect(messageIDHeaders.count == 1)
        #expect(messageIDHeaders.first == "Message-ID: not a valid message id")
    }
}
