// String+MIMETests.swift
// Tests for MIME-related String extensions

import Testing
@testable import SwiftMail

// MARK: - Tag Definitions
extension Tag {
    @Tag static var core: Self
    @Tag static var mime: Self
    @Tag static var fileHandling: Self
    @Tag static var crossPlatform: Self
}

@Suite("String MIME Extensions Tests", .tags(.core, .mime, .fileHandling))
struct StringMIMETests {
    
    @Test("File extension for MIME type resolution", .tags(.crossPlatform))
    func fileExtensionForMIMEType() {
        #if os(macOS)
        // On macOS, we use UTType which might return different extensions
        // We only test that we get a valid extension back
        if let jpegExt = String.fileExtension(for: "image/jpeg") {
            #expect(["jpg", "jpeg"].contains(jpegExt))
        } else {
            Issue.record("Failed to get extension for image/jpeg")
        }
        #else
        // Test common MIME types
        #expect(String.fileExtension(for: "image/jpeg") == "jpg")
        #expect(String.fileExtension(for: "image/png") == "png")
        #expect(String.fileExtension(for: "application/pdf") == "pdf")
        #expect(String.fileExtension(for: "text/plain") == "txt")
        #expect(String.fileExtension(for: "text/html") == "html")
        
        // Test Office document types
        #expect(String.fileExtension(for: "application/msword") == "doc")
        #expect(String.fileExtension(for: "application/vnd.openxmlformats-officedocument.wordprocessingml.document") == "docx")
        #expect(String.fileExtension(for: "application/vnd.ms-excel") == "xls")
        #endif
        
        // Test unknown MIME type (should work the same on all platforms)
        #expect(String.fileExtension(for: "application/unknown") == nil)
    }
    
    @Test("MIME type for file extension resolution", .tags(.crossPlatform)) 
    func mimeTypeForFileExtension() {
        // Test common file extensions (should work the same on all platforms)
        #expect(String.mimeType(for: "jpg") == "image/jpeg")
        #expect(String.mimeType(for: "jpeg") == "image/jpeg")
        #expect(String.mimeType(for: "png") == "image/png")
        #expect(String.mimeType(for: "pdf") == "application/pdf")
        #expect(String.mimeType(for: "txt") == "text/plain")
        #expect(String.mimeType(for: "html") == "text/html")
        #expect(String.mimeType(for: "htm") == "text/html")
        
        // Test Office file extensions
        #expect(String.mimeType(for: "doc") == "application/msword")
        #expect(String.mimeType(for: "docx") == "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        #expect(String.mimeType(for: "xls") == "application/vnd.ms-excel")
        
        // Test case insensitivity
        #expect(String.mimeType(for: "JPG") == "image/jpeg")
        #expect(String.mimeType(for: "PDF") == "application/pdf")
        
        // Test unknown extension
        #expect(String.mimeType(for: "unknown") == "application/octet-stream")
    }
    
    @Test("Extended MIME type support", .tags(.fileHandling))
    func extendedMIMETypes() {
        // Test additional multimedia types - verify they return appropriate types
        let mp4Type = String.mimeType(for: "mp4")
        #expect(mp4Type.hasPrefix("video/"), "MP4 should be a video type, got: \(mp4Type)")
        
        let mp3Type = String.mimeType(for: "mp3")
        #expect(mp3Type.hasPrefix("audio/"), "MP3 should be an audio type, got: \(mp3Type)")
        
        let wavType = String.mimeType(for: "wav")
        #expect(wavType.hasPrefix("audio/"), "WAV should be an audio type, got: \(wavType)")
        
        let gifType = String.mimeType(for: "gif")
        #expect(gifType.hasPrefix("image/"), "GIF should be an image type, got: \(gifType)")
        
        let bmpType = String.mimeType(for: "bmp")
        #expect(bmpType.hasPrefix("image/"), "BMP should be an image type, got: \(bmpType)")
        
        // Test archive types
        let zipType = String.mimeType(for: "zip")
        #expect(zipType.hasPrefix("application/"), "ZIP should be an application type, got: \(zipType)")
        
        // Test development file types
        let jsonType = String.mimeType(for: "json")
        #expect(jsonType.hasPrefix("application/") || jsonType.hasPrefix("text/"), 
               "JSON should be application or text type, got: \(jsonType)")
        
        let cssType = String.mimeType(for: "css")
        #expect(cssType.hasPrefix("text/"), "CSS should be a text type, got: \(cssType)")
        
        let jsType = String.mimeType(for: "js")
        #expect(jsType.hasPrefix("application/") || jsType.hasPrefix("text/"), 
               "JavaScript should be application or text type, got: \(jsType)")
    }
    
    @Test("Edge cases for MIME type resolution")
    func edgeCases() {
        // Test empty string
        #expect(String.mimeType(for: "") == "application/octet-stream")
        
        // Test very long extension
        let longExtension = String(repeating: "a", count: 100)
        #expect(String.mimeType(for: longExtension) == "application/octet-stream")
        
        // Test extension with special characters
        #expect(String.mimeType(for: "file.exe") == "application/octet-stream")
        #expect(String.mimeType(for: "test@test") == "application/octet-stream")
    }
} 