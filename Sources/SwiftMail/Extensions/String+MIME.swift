// String+MIME.swift
// MIME-related extensions for String

import Foundation

#if os(macOS)
import UniformTypeIdentifiers
#endif

extension String {
    /// Get a file extension for a given MIME type
    /// - Parameter mimeType: The full MIME type (e.g., "text/plain", "image/jpeg")
    /// - Returns: An appropriate file extension (without the dot)
    public static func fileExtension(for mimeType: String) -> String? {
        #if os(macOS)
        // Try to get the UTType from the MIME type
        if let utType = UTType(mimeType: mimeType) {
            // Get the preferred file extension
            return utType.preferredFilenameExtension
        }
        return nil
        #else
        // Map common MIME types to extensions
        let mimeToExtension: [String: String] = [
            // Images
            "image/jpeg": "jpg",
            "image/png": "png",
            "image/gif": "gif",
            "image/bmp": "bmp",
            "image/svg+xml": "svg",
            
            // Documents
            "application/pdf": "pdf",
            "text/plain": "txt",
            "text/html": "html",
            "application/msword": "doc",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
            "application/vnd.ms-excel": "xls",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
            
            // Archives
            "application/zip": "zip",
            
            // Audio
            "audio/mpeg": "mp3",
            "audio/wav": "wav",
            "audio/ogg": "ogg",
            
            // Video
            "video/mp4": "mp4",
            "video/x-msvideo": "avi",
            "video/quicktime": "mov",
            
            // Development
            "application/json": "json",
            "text/css": "css",
            "text/javascript": "js",
            "application/xml": "xml"
        ]
        
        return mimeToExtension[mimeType]
        #endif
    }
    
    /// Get MIME type for a file extension
    /// - Parameter fileExtension: The file extension (without dot)
    /// - Returns: The corresponding MIME type, or application/octet-stream if unknown
    public static func mimeType(for fileExtension: String) -> String {
        #if os(macOS)
        // Try to get UTType from file extension
        if let utType = UTType(filenameExtension: fileExtension),
           let mimeType = utType.preferredMIMEType {
            return mimeType
        }
        return "application/octet-stream"
        #else
        // Map common extensions to MIME types
        let extensionToMime: [String: String] = [
            // Images
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "bmp": "image/bmp",
            "svg": "image/svg+xml",
            
            // Documents
            "pdf": "application/pdf",
            "txt": "text/plain",
            "html": "text/html",
            "htm": "text/html",
            "doc": "application/msword",
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xls": "application/vnd.ms-excel",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            
            // Archives
            "zip": "application/zip",
            
            // Audio
            "mp3": "audio/mpeg",
            "wav": "audio/wav",
            "ogg": "audio/ogg",
            
            // Video
            "mp4": "video/mp4",
            "avi": "video/x-msvideo",
            "mov": "video/quicktime",
            
            // Development
            "json": "application/json",
            "css": "text/css",
            "js": "text/javascript",
            "xml": "application/xml"
        ]
        
        return extensionToMime[fileExtension.lowercased()] ?? "application/octet-stream"
        #endif
    }
} 
