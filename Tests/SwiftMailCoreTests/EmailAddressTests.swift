import SwiftMail
import Testing

@Suite("EmailAddress Tests", .serialized, .timeLimit(.minutes(1)))
struct EmailAddressTests {
    @Test("Email address formatting without name")
    func formattingWithoutName() {
        let email = EmailAddress(address: "test@example.com")
        #expect(email.description == "test@example.com")
    }

    @Test("Email address formatting with simple name")
    func formattingWithSimpleName() {
        let email = EmailAddress(name: "John Doe", address: "john@example.com")
        #expect(email.description == "John Doe <john@example.com>")
    }

    @Test("Email address formatting with name containing special characters")
    func formattingWithSpecialCharsInName() {
        let email = EmailAddress(name: "John Doe, Jr.", address: "john@example.com")
        #expect(email.description == "\"John Doe, Jr.\" <john@example.com>")
    }

    @Test("Email address parsing without name")
    func parsingWithoutName() throws {
        let email = EmailAddress("<test@example.com>")
        let validEmail = try #require(email)
        #expect(validEmail.description == "test@example.com")
    }
}
