import Foundation
import Testing
@testable import SwiftIMAP

struct IntUtilitiesTests {
    
    // MARK: - Formatted File Size Tests
    
    @Test
    func testFormattedFileSize() {
        // Test bytes
        let bytes = 500
        let bytesFormatted = bytes.formattedFileSize()
        #expect(bytesFormatted == "500 bytes")
        
        // Test kilobytes
        let kilobytes = 1500
        let kbFormatted = kilobytes.formattedFileSize()
        #expect(kbFormatted == "1.5 KB")
        
        // Test megabytes
        let megabytes = 1500000
        let mbFormatted = megabytes.formattedFileSize()
        #expect(mbFormatted == "1.5 MB")
        
        // Test gigabytes
        let gigabytes = 1500000000
        let gbFormatted = gigabytes.formattedFileSize()
        #expect(gbFormatted == "1.5 GB")
        
        // Test zero
        let zero = 0
        let zeroFormatted = zero.formattedFileSize()
        #expect(zeroFormatted == "Zero KB")
        
        // Test with default locale (system locale)
        let defaultBytes = 500
        let defaultBytesFormatted = defaultBytes.formattedFileSize()
        #expect(!defaultBytesFormatted.isEmpty)
        
        let defaultKilobytes = 1500
        let defaultKbFormatted = defaultKilobytes.formattedFileSize()
        #expect(!defaultKbFormatted.isEmpty)
        
        let defaultMegabytes = 1500000
        let defaultMbFormatted = defaultMegabytes.formattedFileSize()
        #expect(!defaultMbFormatted.isEmpty)
    }
} 
