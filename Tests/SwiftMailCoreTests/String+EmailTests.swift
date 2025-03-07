// String+EmailTests.swift
// Tests for email validation String extension

import XCTest
@testable import SwiftMailCore

final class StringEmailTests: XCTestCase {
    func testValidEmails() {
        // Test basic valid formats
        XCTAssertTrue("user@example.com".isValidEmail())
        XCTAssertTrue("user.name@example.com".isValidEmail())
        XCTAssertTrue("user+tag@example.com".isValidEmail())
        XCTAssertTrue("user@subdomain.example.com".isValidEmail())
        XCTAssertTrue("123@example.com".isValidEmail())
        XCTAssertTrue("user@example.co.uk".isValidEmail())
        
        // Test edge cases that should be valid
        XCTAssertTrue("a@b.cc".isValidEmail())  // Minimal length
        XCTAssertTrue("disposable.style.email.with+symbol@example.com".isValidEmail())
        XCTAssertTrue("other.email-with-hyphen@example.com".isValidEmail())
        XCTAssertTrue("fully-qualified-domain@example.com".isValidEmail())
        XCTAssertTrue("user.name+tag+sorting@example.com".isValidEmail())
        XCTAssertTrue("x@example.com".isValidEmail())  // One-letter local-part
        XCTAssertTrue("example-indeed@strange-example.com".isValidEmail())
        XCTAssertTrue("example@s.example".isValidEmail())  // Short but valid domain
    }
    
    func testInvalidEmails() {
        // Test basic invalid formats
        XCTAssertFalse("".isValidEmail())
        XCTAssertFalse("@example.com".isValidEmail())
        XCTAssertFalse("user@".isValidEmail())
        XCTAssertFalse("user@.com".isValidEmail())
        XCTAssertFalse("user@example".isValidEmail())
        XCTAssertFalse("user.example.com".isValidEmail())
        
        // Test invalid characters and formats
        XCTAssertFalse("user@exam ple.com".isValidEmail())  // Space in domain
        XCTAssertFalse("user@@example.com".isValidEmail())  // Double @
        XCTAssertFalse(".user@example.com".isValidEmail())  // Leading dot
        XCTAssertFalse("user.@example.com".isValidEmail())  // Trailing dot
        XCTAssertFalse("user@example..com".isValidEmail())  // Double dot
        XCTAssertFalse("user@-example.com".isValidEmail())  // Leading hyphen in domain
        XCTAssertFalse("user@example-.com".isValidEmail())  // Trailing hyphen in domain
        XCTAssertFalse("user@.example.com".isValidEmail())  // Leading dot in domain
        XCTAssertFalse("user@example.".isValidEmail())      // Trailing dot in domain
        XCTAssertFalse("user@ex*ample.com".isValidEmail())  // Invalid character
        XCTAssertFalse("user@example.c".isValidEmail())     // TLD too short
        XCTAssertFalse("user name@example.com".isValidEmail()) // Space in local part
    }
} 