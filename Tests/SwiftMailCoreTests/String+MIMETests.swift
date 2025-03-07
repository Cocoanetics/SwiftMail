// String+MIMETests.swift
// Tests for MIME-related String extensions

import XCTest
@testable import SwiftMailCore

final class StringMIMETests: XCTestCase {
    func testFileExtensionForMIMEType() {
        #if os(macOS)
        // On macOS, we use UTType which might return different extensions
        // We only test that we get a valid extension back
        if let jpegExt = String.fileExtension(for: "image/jpeg") {
            XCTAssertTrue(["jpg", "jpeg"].contains(jpegExt))
        } else {
            XCTFail("Failed to get extension for image/jpeg")
        }
        #else
        // Test common MIME types
        XCTAssertEqual(String.fileExtension(for: "image/jpeg"), "jpg")
        XCTAssertEqual(String.fileExtension(for: "image/png"), "png")
        XCTAssertEqual(String.fileExtension(for: "application/pdf"), "pdf")
        XCTAssertEqual(String.fileExtension(for: "text/plain"), "txt")
        XCTAssertEqual(String.fileExtension(for: "text/html"), "html")
        
        // Test Office document types
        XCTAssertEqual(String.fileExtension(for: "application/msword"), "doc")
        XCTAssertEqual(String.fileExtension(for: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"), "docx")
        XCTAssertEqual(String.fileExtension(for: "application/vnd.ms-excel"), "xls")
        #endif
        
        // Test unknown MIME type (should work the same on all platforms)
        XCTAssertNil(String.fileExtension(for: "application/unknown"))
    }
    
    func testMIMETypeForFileExtension() {
        // Test common file extensions (should work the same on all platforms)
        XCTAssertEqual(String.mimeType(for: "jpg"), "image/jpeg")
        XCTAssertEqual(String.mimeType(for: "jpeg"), "image/jpeg")
        XCTAssertEqual(String.mimeType(for: "png"), "image/png")
        XCTAssertEqual(String.mimeType(for: "pdf"), "application/pdf")
        XCTAssertEqual(String.mimeType(for: "txt"), "text/plain")
        XCTAssertEqual(String.mimeType(for: "html"), "text/html")
        XCTAssertEqual(String.mimeType(for: "htm"), "text/html")
        
        // Test Office file extensions
        XCTAssertEqual(String.mimeType(for: "doc"), "application/msword")
        XCTAssertEqual(String.mimeType(for: "docx"), "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        XCTAssertEqual(String.mimeType(for: "xls"), "application/vnd.ms-excel")
        
        // Test case insensitivity
        XCTAssertEqual(String.mimeType(for: "JPG"), "image/jpeg")
        XCTAssertEqual(String.mimeType(for: "PDF"), "application/pdf")
        
        // Test unknown extension
        XCTAssertEqual(String.mimeType(for: "unknown"), "application/octet-stream")
    }
} 