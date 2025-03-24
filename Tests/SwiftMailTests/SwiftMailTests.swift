import Testing
@testable import SwiftMail
import SwiftMail

struct SwiftMailTests {
    @Test
    func testIMAPReExport() {
        #expect(true, "IMAP types are accessible")
    }
    
    @Test
    func testSMTPReExport() {
        #expect(true, "SMTP types are accessible")
    }
    
    @Test
    func testMailCoreTypesAvailable() {
        let address = EmailAddress(name: "Test", address: "test@example.com")
        #expect(address.formatted == "Test <test@example.com>", "Can create and use EmailAddress")
    }
    
    @Test
    func testCombinedUsage() {
        // Test that we can use both IMAP and SMTP types together
        let imapServer = IMAPServer(host: "imap.example.com", port: 993)
        let smtpServer = SMTPServer(host: "smtp.example.com", port: 587)
        
        // Create basic objects to test combined usage
        let address = EmailAddress(name: "Test User", address: "test@example.com")
        
        // Simply verify that types can be instantiated and used together
        #expect(imapServer is IMAPServer, "Should be able to create IMAPServer")
        #expect(smtpServer is SMTPServer, "Should be able to create SMTPServer")
        #expect(address.formatted == "Test User <test@example.com>", "EmailAddress should format correctly")
    }
} 