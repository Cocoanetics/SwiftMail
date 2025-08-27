import XCTest
@testable import SwiftMail

final class MessageBodyTests: XCTestCase {
    
    func testFindHtmlBodyWithCharset() throws {
        // Create a message with HTML content type that includes charset
        let header = MessageInfo(
            sequenceNumber: SequenceNumber(1),
            uid: UID(1),
            subject: "Test Email",
            from: "test@example.com",
            to: ["recipient@example.com"],
            cc: [],
            date: Date(),
            flags: []
        )
        
        let htmlPart = MessagePart(
            section: Section([1]),
            contentType: "text/html; charset=utf-8",
            disposition: nil,
            encoding: "quoted-printable",
            filename: nil,
            contentId: nil,
            data: "<html><body>Test HTML content</body></html>".data(using: .utf8)
        )
        
        let textPart = MessagePart(
            section: Section([2]),
            contentType: "text/plain; charset=utf-8",
            disposition: nil,
            encoding: "quoted-printable",
            filename: nil,
            contentId: nil,
            data: "Test plain text content".data(using: .utf8)
        )
        
        let message = Message(header: header, parts: [htmlPart, textPart])
        
        // Test the new unified API
        let bodies = message.bodies
        XCTAssertEqual(bodies.count, 2, "Should find 2 body parts")
        
        let htmlBodyPart = message.findHtmlBodyPart()
        XCTAssertNotNil(htmlBodyPart, "Should find HTML body part")
        XCTAssertEqual(htmlBodyPart?.contentType, "text/html; charset=utf-8")
        
        let textBodyPart = message.findTextBodyPart()
        XCTAssertNotNil(textBodyPart, "Should find text body part")
        XCTAssertEqual(textBodyPart?.contentType, "text/plain; charset=utf-8")
        
        // Test the legacy API (now fixed)
        let htmlBody = message.htmlBody
        XCTAssertNotNil(htmlBody, "Should find HTML body content")
        XCTAssertTrue(htmlBody?.contains("Test HTML content") == true)
        
        let textBody = message.textBody
        XCTAssertNotNil(textBody, "Should find text body content")
        XCTAssertTrue(textBody?.contains("Test plain text content") == true)
    }
    
    func testFindBodiesExcludesAttachments() throws {
        let header = MessageInfo(
            sequenceNumber: SequenceNumber(1),
            uid: UID(1),
            subject: "Test Email",
            from: "test@example.com",
            to: ["recipient@example.com"],
            cc: [],
            date: Date(),
            flags: []
        )
        
        let htmlPart = MessagePart(
            section: Section([1]),
            contentType: "text/html; charset=utf-8",
            disposition: nil,
            encoding: "quoted-printable",
            filename: nil,
            contentId: nil,
            data: "<html><body>Test HTML content</body></html>".data(using: .utf8)
        )
        
        let attachmentPart = MessagePart(
            section: Section([2]),
            contentType: "text/plain; charset=utf-8",
            disposition: "attachment",
            encoding: "base64",
            filename: "test.txt",
            contentId: nil,
            data: "Test attachment content".data(using: .utf8)
        )
        
        let message = Message(header: header, parts: [htmlPart, attachmentPart])
        
        // Test that attachments are excluded from bodies
        let bodies = message.bodies
        XCTAssertEqual(bodies.count, 1, "Should find only 1 body part (attachment excluded)")
        XCTAssertEqual(bodies.first?.contentType, "text/html; charset=utf-8")
        
        // Test that attachments are still found
        let attachments = message.attachments
        XCTAssertEqual(attachments.count, 1, "Should find 1 attachment")
        XCTAssertEqual(attachments.first?.filename, "test.txt")
    }
    
    func testGetTextContentFromPart() throws {
        let htmlPart = MessagePart(
            section: Section([1]),
            contentType: "text/html; charset=utf-8",
            disposition: nil,
            encoding: "quoted-printable",
            filename: nil,
            contentId: nil,
            data: "<html><body>Test HTML content</body></html>".data(using: .utf8)
        )
        
        // Test the new textContent property
        let content = htmlPart.textContent
        XCTAssertNotNil(content, "Should extract text content from part")
        XCTAssertTrue(content?.contains("Test HTML content") == true)
    }
}
