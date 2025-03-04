import Testing
import SwiftMailCore

@Suite("EmailAddress Tests")
struct EmailAddressTests {
    @Test("Email address formatting without name")
    func testFormattingWithoutName() throws {
        let email = EmailAddress(address: "test@example.com")
        #expect(email.formatted == "test@example.com")
    }
    
    @Test("Email address formatting with simple name")
    func testFormattingWithSimpleName() throws {
        let email = EmailAddress(name: "John Doe", address: "john@example.com")
        #expect(email.formatted == "John Doe <john@example.com>")
    }
    
    @Test("Email address formatting with name containing special characters")
    func testFormattingWithSpecialCharsInName() throws {
        let email = EmailAddress(name: "John Doe, Jr.", address: "john@example.com")
        #expect(email.formatted == "\"John Doe, Jr.\" <john@example.com>")
    }
} 