import Foundation
import Testing
@testable import SwiftMail

@Suite("Problematic Message Tests")
struct ProblematicMessageTests {
    
    @Test("Test problematic message 6068 - no undecoded quoted-printable characters")
    func testProblematicMessage6068() throws {
        let resourcesPath = "Tests/SwiftIMAPTests/Resources"
        let filePath = "\(resourcesPath)/problematic_message_6068.json"
        
        // Check if the file exists
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: filePath) else {
            throw TestFailure("Problematic message file not found at \(filePath)")
        }
        
        // Load the problematic message
        let jsonData = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let message = try JSONDecoder().decode(Message.self, from: jsonData)
        
        // Test each part for undecoded quoted-printable characters
        for (index, part) in message.parts.enumerated() {
            
            // Get the decoded content
            guard let partData = part.data else {
                throw TestFailure("Part \(index + 1) has no data")
            }
            let decodedData = partData.decoded(for: part)
            
            // Convert to string for checking
            guard let decodedString = String(data: decodedData, encoding: .utf8) else {
                throw TestFailure("Could not convert decoded data to UTF-8 string for part \(index + 1)")
            }
            
            // Check for undecoded quoted-printable sequences
            let problematicSequences = [
                "=20",  // Space
                "=A0",  // Non-breaking space
                "=A9",  // Copyright symbol
                "=3D",  // Equals sign
                "=0D",  // Carriage return
                "=0A",  // Line feed
            ]
            
            var foundProblems: [String] = []
            for sequence in problematicSequences {
                if decodedString.contains(sequence) {
                    foundProblems.append(sequence)
                }
            }
            
            if !foundProblems.isEmpty {
                throw TestFailure("Part \(index + 1) contains undecoded quoted-printable sequences: \(foundProblems)")
            }
            
            // Additional check: verify that spaces are properly decoded
            let spaceCount = decodedString.filter { $0 == " " }.count
            let equalsCount = decodedString.filter { $0 == "=" }.count
            
            // The content should have reasonable space count and very few equals signs
            #expect(spaceCount > 0, "Decoded content should contain spaces")
            // HTML content naturally contains many equals signs for attributes, so we don't check this for HTML parts
           if !part.contentType.contains("text/html") {
               #expect(equalsCount < 10, "Decoded content should have very few equals signs (found \(equalsCount))")
           }
        }
    }
    
    @Test("Test specific quoted-printable decoding patterns")
    func testQuotedPrintablePatterns() throws {
        // Test specific patterns that appear in the problematic message
        let testCases = [
            ("=20", " "),           // Space
            ("=A0", " "),           // Non-breaking space (U+00A0) - note: this is different from regular space
            ("=A9", "©"),           // Copyright symbol
            ("=3D", "="),           // Equals sign
            ("=0D", "\r"),          // Carriage return
            ("=0A", "\n"),          // Line feed
            ("=20=20=20", "   "),   // Multiple spaces
            ("Hello=20World", "Hello World"), // Word with space
            ("fami=20liar", "fami liar"), // Split word with space
        ]
        
        for (encoded, expected) in testCases {
            let decoded = encoded.decodeQuotedPrintable()
            
            // Special handling for non-breaking space comparison
            if encoded == "=A0" {
                // =A0 decodes to non-breaking space (U+00A0), not regular space (U+0020)
                let nonBreakingSpace = Character(UnicodeScalar(0x00A0)!)
                #expect(decoded == String(nonBreakingSpace), "Failed to decode '\(encoded)' to non-breaking space, got '\(decoded ?? "nil")'")
            } else {
                #expect(decoded == expected, "Failed to decode '\(encoded)' to '\(expected)', got '\(decoded ?? "nil")'")
            }
        }
    }
}
