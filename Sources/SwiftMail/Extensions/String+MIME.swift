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
            // Use comprehensive MIME type to extension mapping
            return Self.mimeTypeToExtension[mimeType.lowercased()]
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
            // Use comprehensive extension to MIME type mapping
            return Self.extensionToMimeType[fileExtension.lowercased()] ?? "application/octet-stream"
        #endif
    }

    /// Comprehensive extension to MIME type mapping, assembled from the partial
    /// tables defined in `String+MIME+ExtensionToMimeType{A,B,C}.swift`.
    static let extensionToMimeType: [String: String] = {
        var combined = Self.extensionToMimeTypePartA
        combined.merge(Self.extensionToMimeTypePartB) { current, _ in current }
        combined.merge(Self.extensionToMimeTypePartC) { current, _ in current }
        return combined
    }()

    /// Comprehensive MIME type to preferred extension mapping, assembled from the
    /// partial tables defined in `String+MIME+MimeTypeToExtension{A,B,C}.swift`.
    static let mimeTypeToExtension: [String: String] = {
        var combined = Self.mimeTypeToExtensionPartA
        combined.merge(Self.mimeTypeToExtensionPartB) { current, _ in current }
        combined.merge(Self.mimeTypeToExtensionPartC) { current, _ in current }
        return combined
    }()
}
