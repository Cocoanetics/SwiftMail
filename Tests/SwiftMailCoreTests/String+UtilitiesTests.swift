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
        
        // Test invalid characters are removed
        #expect("file:with/invalid\\chars?.txt".sanitizedFileName() == "filewithinvalidchars.txt")
        #expect("doc*with|special<chars>.pdf".sanitizedFileName() == "docwithspecialchars.pdf")

        // Test spaces are preserved exactly
        #expect("my document.pdf".sanitizedFileName() == "my document.pdf")
        #expect("file   with  spaces.txt".sanitizedFileName() == "file   with  spaces.txt")
        
        // Test empty string
        #expect("".sanitizedFileName() == "")
    }
} 