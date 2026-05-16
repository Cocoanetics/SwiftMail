import Foundation
@testable import SwiftMail
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct DataUtilitiesTests {
    // MARK: - Preview Tests

    @Test
    func testPreview() {
        // Test text data preview
        let textString = "This is a sample text for testing the preview function"
        let textData = Data(textString.utf8)
        #expect(textData.preview() == textString)

        // Test truncation for long text
        let longText = String(repeating: "A", count: 1000)
        let longData = Data(longText.utf8)
        let preview = longData.preview()
        #expect(preview.count <= 500)
        // The implementation might not add "..." at the end

        // Test empty data
        let emptyData = Data()
        #expect(emptyData.preview() == "")

        // Test custom max length
        let customMaxText = String(repeating: "B", count: 200)
        let customMaxData = Data(customMaxText.utf8)
        let customPreview = customMaxData.preview(maxLength: 100)
        #expect(customPreview.count <= 100)
        // The implementation might not add "..." at the end

        // Test binary data
        // Create a simple binary data (JPEG signature)
        let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]
        let binaryData = Data(jpegSignature)
        #expect(binaryData.preview().contains("<Binary data:"))
    }

    // MARK: - Text Content Detection Tests

    @Test
    func testIsTextContent() {
        // Test plain text
        let plainText = Data("This is plain text".utf8)
        #expect(plainText.isTextContent() == true)

        // Test HTML content
        let htmlContent = Data("<html><body>This is HTML</body></html>".utf8)
        #expect(htmlContent.isTextContent() == true)

        // Test JSON content
        let jsonContent = Data("{\"key\": \"value\"}".utf8)
        #expect(jsonContent.isTextContent() == true)

        // Test binary data (JPEG signature)
        let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]
        let jpegData = Data(jpegSignature)
        #expect(jpegData.isTextContent() == false)

        // Test binary data (PNG signature)
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let pngData = Data(pngSignature)
        #expect(pngData.isTextContent() == false)

        // Test binary data (PDF signature)
        let pdfSignature = Data("%PDF-1.5".utf8)
        #expect(pdfSignature.isTextContent() == false)

        // Test empty data
        let emptyData = Data()
        #expect(emptyData.isTextContent() == true)
    }
}
