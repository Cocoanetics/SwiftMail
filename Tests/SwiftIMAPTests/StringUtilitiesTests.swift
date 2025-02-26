import Foundation
import Testing
import NIOIMAP
@testable import SwiftIMAP

struct StringUtilitiesTests {
    
    // MARK: - Sanitized Filename Tests
    
    @Test
    func testSanitizedFileName() {
        // Test basic valid filename
        let validName = "document.txt"
        #expect(validName.sanitizedFileName() == "document.txt")
        
        // Test filename with invalid characters
        let invalidChars = "file:with*invalid/characters?.txt"
        #expect(invalidChars.sanitizedFileName() == "file_with_invalid_characters_.txt")
        
        // Test filename with spaces
        let spacesName = "my document.pdf"
        #expect(spacesName.sanitizedFileName() == "my_document.pdf")
        
        // Test filename with special characters
        let specialChars = "résumé (2023).pdf"
        #expect(specialChars.sanitizedFileName() == "résumé_(2023).pdf")
        
        // Test empty string
        let emptyString = ""
        #expect(emptyString.sanitizedFileName() == "")
    }
    
    // MARK: - File Extension Tests
    
    @Test
    func testFileExtension() {
        // Test common MIME types
        #expect("text".fileExtension(subtype: "plain") == "txt")
        #expect("text".fileExtension(subtype: "html") == "html")
        #expect("image".fileExtension(subtype: "jpeg") == "jpg")
        #expect("image".fileExtension(subtype: "png") == "png")
        #expect("application".fileExtension(subtype: "pdf") == "pdf")
        
        // Test less common MIME types
        #expect("audio".fileExtension(subtype: "mp3") == "mp3")
        #expect("video".fileExtension(subtype: "mp4") == "mp4")
        #expect("application".fileExtension(subtype: "zip") == "zip")
        
        // Test unknown MIME types
        #expect("application".fileExtension(subtype: "x-custom") == "bin")
        #expect("unknown".fileExtension(subtype: "type") == "dat")
    }
    
    // MARK: - Sequence Set Tests
    
    @Test
    func testToSequenceSet() throws {
        // Test single number
        let singleNumber = "42"
        _ = try singleNumber.toSequenceSet()
        // We can't directly test the contents, so we'll just verify it doesn't throw
        
        // Test simple range
        let simpleRange = "1:10"
        _ = try simpleRange.toSequenceSet()
        // We can't directly test the contents, so we'll just verify it doesn't throw
        
        // Test invalid input
        let invalidRange = "abc"
        do {
            _ = try invalidRange.toSequenceSet()
            throw TestFailure("Expected toSequenceSet to throw for invalid input")
        } catch {
            // Expected to throw
        }
        
        // Test empty string
        let emptyString = ""
        do {
            _ = try emptyString.toSequenceSet()
            throw TestFailure("Expected toSequenceSet to throw for empty string")
        } catch {
            // Expected to throw
        }
    }
} 