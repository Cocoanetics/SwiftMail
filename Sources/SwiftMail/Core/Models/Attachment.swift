// Attachment.swift
// Common attachment model for email messages

import Foundation

/**
 A struct representing an email attachment
 */
public struct Attachment: Codable, Sendable {
    /** The filename of the attachment */
    public let filename: String

    /** The MIME type of the attachment */
    public let mimeType: String

    /** The data of the attachment */
    public let data: Data

    /** Optional content ID for inline attachments */
    public let contentID: String?

    /** Whether this attachment should be displayed inline */
    public let isInline: Bool

    /**
     Initialize a new attachment
     - Parameters:
     - filename: The filename of the attachment
     - mimeType: The MIME type of the attachment
     - data: The data of the attachment
     - contentID: Optional content ID for inline attachments
     - isInline: Whether this attachment should be displayed inline (default: false)
     */
    public init(filename: String, mimeType: String, data: Data, contentID: String? = nil, isInline: Bool = false) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentID = contentID
        self.isInline = isInline
    }

    /**
     Initialize a new attachment from a file URL
     - Parameters:
     - fileURL: The URL of the file to attach
     - mimeType: The MIME type of the attachment (if nil, will attempt to determine from file extension)
     - contentID: Optional content ID for inline attachments
     - isInline: Whether this attachment should be displayed inline (default: false)
     - Throws: An error if the file cannot be read
     */
    public init(fileURL: URL, mimeType: String? = nil, contentID: String? = nil, isInline: Bool = false) throws {
        // Get the filename from the URL
        self.filename = fileURL.lastPathComponent

        // Determine MIME type if not provided
        if let providedMimeType = mimeType {
            self.mimeType = providedMimeType
        } else {
            self.mimeType = Self.mimeType(forPathExtension: fileURL.pathExtension.lowercased())
        }

        // Read the file data
        self.data = try Data(contentsOf: fileURL)

        // Set content ID and inline flag
        self.contentID = contentID
        self.isInline = isInline
    }

    /// Map of file extensions to MIME types used for guessing the content type of attached files.
    private static let mimeTypesByExtension: [String: String] = [
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
        "docx": "application/msword",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.ms-excel",
        "zip": "application/zip"
    ]

    /// Resolve a lowercased file extension to its MIME type, falling back to "application/octet-stream".
    private static func mimeType(forPathExtension pathExtension: String) -> String {
        mimeTypesByExtension[pathExtension] ?? "application/octet-stream"
    }
}
