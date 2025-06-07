// String+UtilitiesTests.swift
// Tests for general String utilities

import Testing
@testable import SwiftMail

@Suite("String Utilities Tests")
struct StringUtilitiesTests {
    
    @Test("Sanitized file name validation")
    func sanitizedFileName() {
        // Test valid filenames remain unchanged
        #expect("document.txt".sanitizedFileName() == "document.txt")
        #expect("image.jpg".sanitizedFileName() == "image.jpg")
        
        // Test invalid characters are replaced
        #expect("file:with/invalid\\chars?.txt".sanitizedFileName() == "file_with_invalid_chars_.txt")
        #expect("doc*with|special<chars>.pdf".sanitizedFileName() == "doc_with_special_chars_.pdf")
        
        // Test spaces are replaced with underscores
        #expect("my document.pdf".sanitizedFileName() == "my_document.pdf")
        #expect("file with spaces.txt".sanitizedFileName() == "file_with_spaces.txt")
        
        // Test empty string
        #expect("".sanitizedFileName() == "")
    }
} 