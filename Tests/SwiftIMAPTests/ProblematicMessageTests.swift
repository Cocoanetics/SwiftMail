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
        
        print("📧 Testing problematic message 6068")
        print("  Subject: \(message.header.subject ?? "no subject")")
        print("  Parts: \(message.parts.count)")
        
        // Test each part for undecoded quoted-printable characters
        for (index, part) in message.parts.enumerated() {
            print("  Part \(index + 1): \(part.contentType)")
            print("    Encoding: \(part.encoding ?? "none")")
            
            // Get the decoded content
            guard let partData = part.data else {
                throw TestFailure("Part \(index + 1) has no data")
            }
            let decodedData = try partData.decoded(for: part)
            
            // Convert to string for checking
            guard let decodedString = String(data: decodedData, encoding: .utf8) else {
                throw TestFailure("Could not convert decoded data to UTF-8 string for part \(index + 1)")
            }
            
            print("    Decoded content length: \(decodedString.count) characters")
            
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
                print("    ❌ Found undecoded quoted-printable sequences: \(foundProblems)")
                
                // Show a sample of the problematic content
                let lines = decodedString.components(separatedBy: CharacterSet.newlines)
                let sampleLines = Array(lines.prefix(5))
                print("    Sample content:")
                for (lineIndex, line) in sampleLines.enumerated() {
                    print("      Line \(lineIndex + 1): \(line)")
                }
                
                throw TestFailure("Part \(index + 1) contains undecoded quoted-printable sequences: \(foundProblems)")
            } else {
                print("    ✅ No undecoded quoted-printable sequences found")
            }
            
            // Additional check: verify that spaces are properly decoded
            let spaceCount = decodedString.filter { $0 == " " }.count
            let equalsCount = decodedString.filter { $0 == "=" }.count
            print("    Spaces: \(spaceCount), Equals signs: \(equalsCount)")
            
            // The content should have reasonable space count and very few equals signs
            #expect(spaceCount > 0, "Decoded content should contain spaces")
            #expect(equalsCount < 10, "Decoded content should have very few equals signs (found \(equalsCount))")
        }
        
        print("✅ All parts decoded successfully without quoted-printable artifacts")
    }
    
    @Test("Test specific quoted-printable decoding patterns")
    func testQuotedPrintablePatterns() throws {
        // Test specific patterns that appear in the problematic message
        let testCases = [
            ("=20", " "),           // Space
            ("=A0", " "),           // Non-breaking space (should become regular space)
            ("=A9", "©"),           // Copyright symbol
            ("=3D", "="),           // Equals sign
            ("=0D", "\r"),          // Carriage return
            ("=0A", "\n"),          // Line feed
            ("=20=20=20", "   "),   // Multiple spaces
            ("Hello=20World", "Hello World"), // Word with space
            ("fami=20liar", "familiar"), // Split word
        ]
        
        for (encoded, expected) in testCases {
            let decoded = encoded.decodeQuotedPrintable()
            #expect(decoded == expected, "Failed to decode '\(encoded)' to '\(expected)', got '\(decoded)'")
        }
        
        print("✅ All quoted-printable patterns decoded correctly")
    }
}
