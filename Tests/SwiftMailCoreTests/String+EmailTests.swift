// String+EmailTests.swift
// Tests for email validation String extension

import Testing
@testable import SwiftMail

// Use existing tag definitions
extension Tag {
    @Tag static var core: Self
    @Tag static var validation: Self
    @Tag static var security: Self
}

@Suite("String Email Validation Tests", .serialized, .tags(.core, .validation), .timeLimit(.minutes(1)))
struct StringEmailTests {
    private let validEmails = [
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
        "user123@test-domain.org",
        "user@mail.some-company.com",  // Hyphens in intermediate domain labels
        "user@sub1.sub-2.example.com",   // Multiple hyphenated subdomains
        "user@a1-b2.c3-d4.example.org"   // Digits + hyphens in subdomains
    ]

    private let invalidEmails = [
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
    ]

    @Test("Valid email addresses should pass validation", .tags(.validation))
    func validEmailsPassValidation() {
        for email in validEmails {
            #expect(email.isValidEmail(), "'\(email)' should be a valid email address")
        }
    }

    @Test("Invalid email addresses should fail validation", .tags(.validation, .security))
    func invalidEmailsFailValidation() {
        for email in invalidEmails {
            #expect(!email.isValidEmail(), "'\(email)' should be an invalid email address")
        }
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
            #expect(
                !maliciousEmail.isValidEmail(),
                "Malicious input '\(maliciousEmail)' should be rejected"
            )
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

    @Test("Quoted local parts (RFC 5321 Quoted-string) are accepted")
    func testQuotedLocalPart() {
        // Japanese carrier addresses whose local part ends with a dot or has consecutive dots
        // are sent quoted on the wire
        #expect("\"taro.\"@docomo.ne.jp".isValidEmail())
        #expect("\"taro..yamada\"@ezweb.ne.jp".isValidEmail())
        #expect("\"john doe\"@example.com".isValidEmail())
        #expect("\"a\\\"b\"@example.com".isValidEmail(), "escaped quote inside")
        // The unquoted forms stay invalid (not RFC 5321 dot-strings)
        #expect(!"taro.@docomo.ne.jp".isValidEmail())
        #expect(!".taro@docomo.ne.jp".isValidEmail())
        // Broken quoting stays invalid
        #expect(!"\"taro@docomo.ne.jp".isValidEmail())
        #expect(!"\"\"@example.com".isValidEmail(), "empty quoted string")
        #expect(!"\"a\"b\"@example.com".isValidEmail(), "unescaped quote inside")
        #expect(!"\"日本\"@example.com".isValidEmail(), "non-ASCII inside quotes")
        // A trailing line break must not pass (it would end the SMTP command early)
        #expect(!"user@example.com\n".isValidEmail())
        #expect(!"\"taro.\"@docomo.ne.jp\r\n".isValidEmail())
    }

    @Test("RFC 5322 atext local parts that AddressParser reads as one mailbox are accepted")
    func testAtextLocalParts() {
        // The parser and formatter take these as canonical mailboxes; SMTP must accept them
        // too, or the header names an address the envelope refuses (or vice versa)
        let addresses = [
            "o'neil@example.com", "!user@example.com", "{x}@example.com", "a#b@example.com", "~me@example.com"
        ]
        for address in addresses {
            #expect(address.isValidEmail(), "\(address)")
            #expect(EmailAddress(address: address).description == address, "header form stays the same address")
        }
        // Still refused: non-ASCII, white space, control characters, over-long local parts, bad domains
        #expect(!"用户@example.com".isValidEmail())
        #expect(!"o'neil @example.com".isValidEmail())
        #expect(!"o'neil@example.com\r\nBcc: x@example.com".isValidEmail())
        #expect(!(String(repeating: "'", count: 65) + "@example.com").isValidEmail())
        #expect(!"o'neil@192.168.1.1".isValidEmail())
        #expect(!"o'neil@example".isValidEmail())
    }

    @Test("A quoted local part is held to the RFC 5321 64-octet limit, quotes and escapes included")
    func testQuotedLocalPartOctetLimit() {
        let atLimit = "\"" + String(repeating: "x", count: 62) + "\"@example.com"
        #expect(atLimit.isValidEmail(), "64 octets including the quotes")
        let overLimit = "\"" + String(repeating: "x", count: 64) + "\"@example.com"
        #expect(!overLimit.isValidEmail(), "66 octets")
        let escaped = "\"" + String(repeating: "\\\"", count: 32) + "\"@example.com"
        #expect(!escaped.isValidEmail(), "each quoted-pair is two octets")
    }
}
