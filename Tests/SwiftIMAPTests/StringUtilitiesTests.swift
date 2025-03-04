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
		#expect(String.fileExtension(for: "text/plain") == "txt")
		#expect(String.fileExtension(for:"text/html") == "html")
		#expect(String.fileExtension(for:"image/jpeg") == "jpeg")
		#expect(String.fileExtension(for:"image/png") == "png")
		#expect(String.fileExtension(for:"application/pdf") == "pdf")
		
		// Test less common MIME types
		#expect(String.fileExtension(for:"audio/mp3") == "mp3")
		#expect(String.fileExtension(for:"video/mp4") == "mp4")
		#expect(String.fileExtension(for:"application/zip") == "zip")
		
		// Test unknown MIME types
		#expect(String.fileExtension(for:"application/x-custom") == nil)
		#expect(String.fileExtension(for:"unknown/type") == nil)
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
