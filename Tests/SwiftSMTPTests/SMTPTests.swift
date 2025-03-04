import Testing
@testable import SwiftSMTP

struct SMTPTests {
    @Test
    func testPlaceholder() {
        // This is just a placeholder test to ensure the test target can compile
        // Once you implement SwiftSMTP functionality, replace with actual tests
        #expect(true)
    }
    
    @Test
    func testSMTPServerInit() {
        // Test that we can initialize an SMTPServer
        let server = SMTPServer(host: "smtp.example.com", port: 587)
        // Since host and port are private, we can only verify the server was created
        #expect(server is SMTPServer, "Should create an SMTPServer instance")
    }
    
    @Test
    func testEmailInit() {
        // Test email initialization
        let sender = SwiftSMTP.EmailAddress(name: "Sender", address: "sender@example.com")
        let recipient1 = SwiftSMTP.EmailAddress(address: "recipient1@example.com")
        let recipient2 = SwiftSMTP.EmailAddress(name: "Recipient 2", address: "recipient2@example.com")
        
        let email = Email(
            sender: sender,
            recipients: [recipient1, recipient2],
            subject: "Test Subject",
            body: "Test Body"
        )
        
        #expect(email.sender.address == "sender@example.com", "Sender address should match")
        #expect(email.recipients.count == 2, "Should have 2 recipients")
        #expect(email.subject == "Test Subject", "Subject should match")
        #expect(email.body == "Test Body", "Body should match")
    }
    
    @Test
    func testEmailStringInit() {
        // Test the string-based initializer
        let email = Email(
            sender: "Test Sender",
            senderAddress: "sender@example.com",
            recipients: ["recipient@example.com"],
            subject: "Test Subject",
            body: "Test Body"
        )
        
        #expect(email.sender.name == "Test Sender", "Sender name should match")
        #expect(email.sender.address == "sender@example.com", "Sender address should match")
        #expect(email.recipients.count == 1, "Should have 1 recipient")
        #expect(email.recipients[0].address == "recipient@example.com", "Recipient address should match")
    }
} 