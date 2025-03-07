// String+UtilitiesTests.swift
// Tests for general String utilities

import XCTest
@testable import SwiftMailCore

final class StringUtilitiesTests: XCTestCase {
    func testSanitizedFileName() {
        // Test valid filenames remain unchanged
        XCTAssertEqual("document.txt".sanitizedFileName(), "document.txt")
        XCTAssertEqual("image.jpg".sanitizedFileName(), "image.jpg")
        
        // Test invalid characters are replaced
        XCTAssertEqual("file:with/invalid\\chars?.txt".sanitizedFileName(), "file_with_invalid_chars_.txt")
        XCTAssertEqual("doc*with|special<chars>.pdf".sanitizedFileName(), "doc_with_special_chars_.pdf")
        
        // Test spaces are replaced with underscores
        XCTAssertEqual("my document.pdf".sanitizedFileName(), "my_document.pdf")
        XCTAssertEqual("file with spaces.txt".sanitizedFileName(), "file_with_spaces.txt")
        
        // Test empty string
        XCTAssertEqual("".sanitizedFileName(), "")
    }
} 