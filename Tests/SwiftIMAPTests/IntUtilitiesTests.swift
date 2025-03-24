import Foundation
import Testing
@testable import SwiftMail

struct IntUtilitiesTests {
    
    // MARK: - Formatted File Size Tests
    
    @Test
    func testFormattedFileSize() {
        let enUSLocale = Locale(identifier: "en_US")
        
        // Test bytes
        let bytes = 500
        let bytesFormatted = bytes.formattedFileSize(locale: enUSLocale)
        #expect(bytesFormatted == "500 byte")
        
        // Test kilobytes
        let kilobytes = 1500
        let kbFormatted = kilobytes.formattedFileSize(locale: enUSLocale)
        #expect(kbFormatted == "1.5 kB")
        
        // Test megabytes
        let megabytes = 1500000
        let mbFormatted = megabytes.formattedFileSize(locale: enUSLocale)
        #expect(mbFormatted == "1.5 MB")
        
        // Test gigabytes
        let gigabytes = 1500000000
        let gbFormatted = gigabytes.formattedFileSize(locale: enUSLocale)
        #expect(gbFormatted == "1.5 GB")
        
        // Test zero
        let zero = 0
        let zeroFormatted = zero.formattedFileSize(locale: enUSLocale)
        #expect(zeroFormatted == "0 byte")
        
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
