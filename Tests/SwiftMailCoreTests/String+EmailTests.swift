// String+EmailTests.swift
// Tests for email validation String extension

import Testing
@testable import SwiftMail

// Use existing tag definitions
extension Tag {
    @Tag static var validation: Self
    @Tag static var security: Self
}

@Suite("String Email Validation Tests", .tags(.core, .validation))
struct StringEmailTests {
    
    @Test("Valid email addresses should pass validation", .tags(.validation),
          arguments: [
            "user@example.com",
            "user.name@example.com", 
            "user+tag@example.com",
            "user@subdomain.example.com",
            "123@example.com",
            "user@example.co.uk",
            "a@b.cc",  // Minimal length
            "disposable.style.email.with+symbol@example.com",
            "other.email-with-hyphen@example.com",
            "fully-qualified-domain@example.com",
            "user.name+tag+sorting@example.com",
            "x@example.com",  // One-letter local-part
            "example-indeed@strange-example.com",
            "example@s.example",  // Short but valid domain
            "test.email.with+symbol@example.com",
            "user123@test-domain.org"
          ])
    func validEmails(email: String) {
        #expect(email.isValidEmail(), "'\(email)' should be a valid email address")
    }
    
    @Test("Invalid email addresses should fail validation", .tags(.validation, .security),
          arguments: [
            "",
            "@example.com",
            "user@",
            "user@.com",
            "user@example",
            "user.example.com",
            "user@exam ple.com",  // Space in domain
            "user@@example.com",  // Double @
            ".user@example.com",  // Leading dot
            "user.@example.com",  // Trailing dot
            "user@example..com",  // Double dot
            "user@-example.com",  // Leading hyphen in domain
            "user@example-.com",  // Trailing hyphen in domain
            "user@.example.com",  // Leading dot in domain
            "user@example.",      // Trailing dot in domain
            "user@ex*ample.com",  // Invalid character
            "user@example.c",     // TLD too short
            "user name@example.com", // Space in local part
            "user<script>@example.com", // Security: HTML injection attempt
            "user@example.com; DROP TABLE users;", // Security: SQL injection attempt
            "user@192.168.1.1", // IP addresses without proper format
            "user@[192.168.1.1", // Malformed IP bracket
            "user@192.168.1.1]" // Malformed IP bracket
          ])
    func invalidEmails(email: String) {
        #expect(!email.isValidEmail(), "'\(email)' should be an invalid email address")
    }
    
    @Test("Edge cases for email validation")
    func emailEdgeCases() {
        // Test specific edge cases individually for better diagnostics
        #expect("a@b.cc".isValidEmail(), "Minimal valid email should pass")
        #expect(!"".isValidEmail(), "Empty string should be invalid")
        #expect(!"@".isValidEmail(), "Single @ symbol should be invalid")
        #expect(!"user@@example.com".isValidEmail(), "Double @ should be invalid")
        #expect(!"user@example..com".isValidEmail(), "Double dots in domain should be invalid")
    }
    
    @Test("International domain names", .tags(.validation))
    func internationalDomains() {
        // These might be valid depending on implementation
        let internationalEmails = [
            "user@münchen.de",
            "test@café.com",
            "email@測試.com"
        ]
        
        for email in internationalEmails {
            _ = email.isValidEmail() // Just verify that the function doesn't crash
        }
    }
    
    @Test("Security and injection protection", .tags(.security))
    func securityTests() {
        let maliciousInputs = [
            "user<script>alert('xss')</script>@example.com",
            "user'; DROP TABLE users; --@example.com",
                         "user@example.com\\r\\nBCC: evil@hacker.com",
             "user@example.com\\nSubject: Spam",
                         "user\\u{0000}@example.com", // Null byte injection
             "user@exam\\u{0000}ple.com"
        ]
        
        for maliciousEmail in maliciousInputs {
            #expect(!maliciousEmail.isValidEmail(), 
                   "Malicious input '\(maliciousEmail)' should be rejected")
        }
    }
    
    @Test("Performance with long inputs", .tags(.validation))
    func performanceLongInputs() {
        // Test very long email addresses
        let longLocalPart = String(repeating: "a", count: 1000)
        let longEmail = "\(longLocalPart)@example.com"
        
        // Should handle long inputs gracefully (likely invalid due to length)
        let result = longEmail.isValidEmail()
        #expect(!result, "Extremely long email should be invalid")
        
        // Test long domain
        let longDomain = String(repeating: "test.", count: 50) + "com"
        let longDomainEmail = "user@\(longDomain)"
        _ = longDomainEmail.isValidEmail()
    }
    
    @Test("Unicode and special character handling", .tags(.validation))
    func unicodeHandling() {
        let unicodeEmails = [
            "用户@example.com", // Chinese characters in local part
            "user@раздел.com", // Cyrillic in domain
            "tëst@example.com", // Accented characters
            "user+tag@example.com", // Plus sign (should be valid)
            "user=tag@example.com", // Equals sign
            "user%tag@example.com" // Percent sign
        ]
        
        for email in unicodeEmails {
            _ = email.isValidEmail() // Just verify that the function doesn't crash
        }
        
        // Test that plus sign is typically allowed (common use case)
        #expect("user+tag@example.com".isValidEmail(), "Plus sign should typically be allowed in email addresses")
    }
} 

