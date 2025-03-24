import Testing
import SwiftMail

@Suite("EmailAddress Tests")
struct EmailAddressTests {
    @Test("Email address formatting without name")
    func testFormattingWithoutName() throws {
        let email = EmailAddress(address: "test@example.com")
        #expect(email.description == "test@example.com")
    }
    
    @Test("Email address formatting with simple name")
    func testFormattingWithSimpleName() throws {
        let email = EmailAddress(name: "John Doe", address: "john@example.com")
        #expect(email.description == "John Doe <john@example.com>")
    }
    
    @Test("Email address formatting with name containing special characters")
    func testFormattingWithSpecialCharsInName() throws {
        let email = EmailAddress(name: "John Doe, Jr.", address: "john@example.com")
        #expect(email.description == "\"John Doe, Jr.\" <john@example.com>")
    }
} 