import Foundation
import Testing
import NIO
@testable import SwiftMail

struct ByteBufferStringValueTests {
    
    // MARK: - String Value Tests
    
    @Test
    func testStringValue() {
        // Create a ByteBuffer with a string
        var buffer = ByteBufferAllocator().buffer(capacity: 100)
        let testString = "Hello, World!"
        buffer.writeString(testString)
        
        // Test stringValue property
        #expect(buffer.stringValue == testString)
        
        // Test with empty buffer
        let emptyBuffer = ByteBufferAllocator().buffer(capacity: 0)
        #expect(emptyBuffer.stringValue == "")
        
        // Test with non-ASCII characters
        let unicodeString = "こんにちは世界"
        var unicodeBuffer = ByteBufferAllocator().buffer(capacity: 100)
        unicodeBuffer.writeString(unicodeString)
        #expect(unicodeBuffer.stringValue == unicodeString)
        
        // Test with mixed content
        var mixedBuffer = ByteBufferAllocator().buffer(capacity: 100)
        mixedBuffer.writeString("Text: ")
        mixedBuffer.writeInteger(UInt8(123))
        #expect(mixedBuffer.stringValue.starts(with: "Text: "))
    }
} 