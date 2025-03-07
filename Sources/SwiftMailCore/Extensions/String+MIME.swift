// String+MIME.swift
// MIME-related extensions for String

import Foundation

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

extension String {
    /// Sanitize a filename to ensure it's valid
    /// - Returns: A sanitized filename
    public func sanitizedFileName() -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return self
            .components(separatedBy: invalidCharacters)
            .joined(separator: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
    
    #if canImport(UniformTypeIdentifiers)
    /// Get a file extension for a given MIME type
    /// - Parameter mimeType: The full MIME type (e.g., "text/plain", "image/jpeg")
    /// - Returns: An appropriate file extension (without the dot)
    public static func fileExtension(for mimeType: String) -> String? {
        // Try to get the UTType from the MIME type
        if let utType = UTType(mimeType: mimeType) {
            // Get the preferred file extension
            return utType.preferredFilenameExtension
        }
        return nil
    }
    
    /// Get MIME type for a file extension
    /// - Parameter fileExtension: The file extension (without dot)
    /// - Returns: The corresponding MIME type, or application/octet-stream if unknown
    public static func mimeType(for fileExtension: String) -> String {
        // Try to get UTType from file extension
        if let utType = UTType(filenameExtension: fileExtension),
           let mimeType = utType.preferredMIMEType {
            return mimeType
        }
        return "application/octet-stream"
    }
    #else
    // MIME type mappings for Linux and other platforms
    private static let mimeTypes: [String: String] = {
        loadMimeTypeMappings()
    }()
    
    private static let extensionTypes: [String: String] = {
        // Create reverse mapping
        var extMap: [String: String] = [:]
        for (ext, mime) in mimeTypes {
            extMap[mime] = ext
        }
        return extMap
    }()
    
    private static func loadMimeTypeMappings() -> [String: String] {
        let path = "/etc/mime.types"
        guard let contents = try? String(contentsOfFile: path) else {
            return fallbackMimeTypes()
        }
        
        var mimeMap: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            
            let parts = trimmed.split(separator: .whitespaces, omittingEmptySubsequences: true)
            if let mimeType = parts.first {
                for ext in parts.dropFirst() {
                    mimeMap[String(ext)] = String(mimeType)
                }
            }
        }
        
        // If the system file was empty or had no valid entries, use fallback
        return mimeMap.isEmpty ? fallbackMimeTypes() : mimeMap
    }
    
    private static func fallbackMimeTypes() -> [String: String] {
        return [
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "svg": "image/svg+xml",
            "pdf": "application/pdf",
            "txt": "text/plain",
            "html": "text/html",
            "htm": "text/html",
            "doc": "application/msword",
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xls": "application/vnd.ms-excel",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "zip": "application/zip"
        ]
    }
    
    /// Get a file extension for a given MIME type
    /// - Parameter mimeType: The full MIME type (e.g., "text/plain", "image/jpeg")
    /// - Returns: An appropriate file extension (without the dot)
    public static func fileExtension(for mimeType: String) -> String? {
        return extensionTypes[mimeType]
    }
    
    /// Get MIME type for a file extension
    /// - Parameter fileExtension: The file extension (without dot)
    /// - Returns: The corresponding MIME type, or application/octet-stream if unknown
    public static func mimeType(for fileExtension: String) -> String {
        return mimeTypes[fileExtension.lowercased()] ?? "application/octet-stream"
    }
    #endif
} 
