// String+MIME.swift
// MIME-related extensions for String.
//
// Backed by SwiftCross's `UTType`, which re-exports the real
// UniformTypeIdentifiers.UTType on Apple platforms and provides a portable
// extension ↔ MIME-type shim everywhere else.

import SwiftCross

extension String {
    /// Get a file extension for a given MIME type
    /// - Parameter mimeType: The full MIME type (e.g., "text/plain", "image/jpeg")
    /// - Returns: An appropriate file extension (without the dot), or nil if unknown
    public static func fileExtension(for mimeType: String) -> String? {
        UTType(mimeType: mimeType)?.preferredFilenameExtension
    }

    /// Get MIME type for a file extension
    /// - Parameter fileExtension: The file extension (without dot)
    /// - Returns: The corresponding MIME type, or application/octet-stream if unknown
    public static func mimeType(for fileExtension: String) -> String {
        UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
