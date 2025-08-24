import Foundation
import Testing
@testable import SwiftMail

// Add new tag for problematic message tests
extension Tag {
    @Tag static var problematic: Self
}

@Suite("Problematic Message Tests", .tags(.imap, .decoding, .problematic))
struct ProblematicMessageTests {
    
    // MARK: - Test Resources
    
    func getResourceURL(for name: String, withExtension ext: String) -> URL? {
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
    }
    
    func loadMessageFromJSON(name: String) throws -> Message {
        guard let url = getResourceURL(for: name, withExtension: "json") else {
            throw TestFailure("Failed to locate resource: \(name).json")
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(Message.self, from: data)
        } catch {
            throw TestFailure("Failed to decode message from JSON: \(error)")
        }
    }
    
    // MARK: - Problematic Message 6068 Tests
    
    @Test("Message 6068 text body should be decodable", .tags(.decoding, .problematic))
    func message6068TextBodyShouldBeDecodable() throws {
        // Load the problematic message from JSON
        let message = try loadMessageFromJSON(name: "problematic_message_6068")
        
        // Verify the message has the expected UID
        #expect(message.uid?.value == 6068)
        #expect(message.subject?.contains("Apple") == true)
        
        // Check that the message has text parts with data
        let textParts = message.parts.filter { $0.contentType.lowercased() == "text/plain" }
        #expect(textParts.count > 0, "Message should have text/plain parts")
        
        let textPart = textParts.first!
        #expect(textPart.data != nil, "Text part should have data")
        #expect(textPart.data!.count > 0, "Text part data should not be empty")
        #expect(textPart.encoding == "QUOTED-PRINTABLE", "Text part should be quoted-printable encoded")
        
        // Test the textBody computed property - this should fail currently
        let textBody = message.textBody
        #expect(textBody != nil, "textBody should not be nil")
        if let textBody = textBody {
            #expect(textBody.count > 0, "textBody should not be empty")
            #expect(textBody.contains("Hallo Oliver Drobnik"), "textBody should contain expected content")
        }
    }
    
    @Test("Message 6068 HTML body should be decodable", .tags(.decoding, .problematic))
    func message6068HtmlBodyShouldBeDecodable() throws {
        // Load the problematic message from JSON
        let message = try loadMessageFromJSON(name: "problematic_message_6068")
        
        // Verify the message has the expected UID
        #expect(message.uid?.value == 6068)
        
        // Check that the message has HTML parts with data
        let htmlParts = message.parts.filter { $0.contentType.lowercased() == "text/html" }
        #expect(htmlParts.count > 0, "Message should have text/html parts")
        
        let htmlPart = htmlParts.first!
        #expect(htmlPart.data != nil, "HTML part should have data")
        #expect(htmlPart.data!.count > 0, "HTML part data should not be empty")
        #expect(htmlPart.encoding == "QUOTED-PRINTABLE", "HTML part should be quoted-printable encoded")
        
        // Test the htmlBody computed property - this should fail currently
        let htmlBody = message.htmlBody
        #expect(htmlBody != nil, "htmlBody should not be nil")
        if let htmlBody = htmlBody {
            #expect(htmlBody.count > 0, "htmlBody should not be empty")
            #expect(htmlBody.contains("<html>"), "htmlBody should contain HTML content")
            #expect(htmlBody.contains("Hallo Oliver Drobnik"), "htmlBody should contain expected content")
        }
    }
    
    @Test("Message 6068 raw part data should be accessible", .tags(.decoding, .problematic))
    func message6068RawPartDataShouldBeAccessible() throws {
        // Load the problematic message from JSON
        let message = try loadMessageFromJSON(name: "problematic_message_6068")
        
        // Test text part raw data
        let textParts = message.parts.filter { $0.contentType.lowercased() == "text/plain" }
        let textPart = textParts.first!
        
        // The data should already be decoded from base64 by the JSON decoder
        #expect(textPart.data != nil, "Text part should have data")
        #expect(textPart.data!.count > 0, "Text part data should not be empty")
        
        // Test HTML part raw data
        let htmlParts = message.parts.filter { $0.contentType.lowercased() == "text/html" }
        let htmlPart = htmlParts.first!
        
        #expect(htmlPart.data != nil, "HTML part should have data")
        #expect(htmlPart.data!.count > 0, "HTML part data should not be empty")
        
        // Try to decode as UTF-8 strings
        let rawText = String(data: textPart.data!, encoding: .utf8)
        let rawHtml = String(data: htmlPart.data!, encoding: .utf8)
        
        #expect(rawText != nil, "Raw text should be valid UTF-8")
        #expect(rawHtml != nil, "Raw HTML should be valid UTF-8")
        
        // The raw content should be quoted-printable encoded
        #expect(rawText!.contains("=20"), "Raw text should contain quoted-printable encoding")
        #expect(rawHtml!.contains("=20"), "Raw HTML should contain quoted-printable encoding")
    }
}
