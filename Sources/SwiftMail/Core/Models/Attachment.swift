// Attachment.swift
// Common attachment model for email messages

import Foundation
import SwiftCross

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
     Initialize a new attachment from a file URL.

     - Parameters:
     - fileURL: The URL of the file to attach
     - mimeType: The MIME type of the attachment (if nil, will attempt to determine from file extension)
     - contentID: Optional content ID for inline attachments
     - isInline: Whether this attachment should be displayed inline (default: false)
     - Throws: An error if the file cannot be read
     */
    public init(fileURL: URL, mimeType: String? = nil, contentID: String? = nil, isInline: Bool = false) throws {
        self.filename = fileURL.lastPathComponent
        self.mimeType = mimeType ?? Self.mimeType(for: fileURL.pathExtension.lowercased())
        self.data = try Data(contentsOf: fileURL)
        self.contentID = contentID
        self.isInline = isInline
    }

    /// Extensions the type database does not resolve.
    ///
    /// Kept deliberately tiny. A hand-maintained table is the thing that
    /// produced the wrong types this replaced, so an entry belongs here only
    /// while `UTType` genuinely does not know the extension.
    private static let additionalMIMETypes: [String: String] = [
        "md": "text/markdown",
        "markdown": "text/markdown"
    ]

    /// The MIME type for a file extension, falling back to
    /// `application/octet-stream` — callers can always pass `mimeType:`
    /// explicitly.
    ///
    /// The answer comes from `UTType`, which SwiftCross ships as a generated
    /// table so every platform agrees. The lookup this replaced was a short
    /// hand-maintained list that had gone stale in the silent direction: a
    /// missing or wrong entry still produces a *plausible* Content-Type, never
    /// an error, so it surfaced only when a recipient's client trusted the
    /// header over the filename. `.docx` and `.xlsx` were declared as their
    /// pre-2007 equivalents, and anything not in the list — `.csv`, `.pptx`,
    /// `.rtf`, `.json` — came out as `application/octet-stream`.
    static func mimeType(for pathExtension: String) -> String {
        let normalized = pathExtension.lowercased()
        return UTType(filenameExtension: normalized)?.preferredMIMEType
            ?? additionalMIMETypes[normalized]
            ?? "application/octet-stream"
    }
}
