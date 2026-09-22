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

    /// The MIME types SwiftMail guarantees, identical on every platform.
    ///
    /// `UTType` is not one table: on Apple platforms SwiftCross re-exports
    /// Apple's UniformTypeIdentifiers, and elsewhere it substitutes its own.
    /// The two disagree — `.rtf` is `text/rtf` on Apple and `application/rtf`
    /// on Linux, `.xml` is `application/xml` against `text/xml` — so relying
    /// on it alone would make the Content-Type of an attachment depend on
    /// which machine composed the message. For a library whose same code runs
    /// on all of them, that is its own defect.
    ///
    /// So the types that matter for mail are pinned here and the database is
    /// consulted only beyond them. Pinning is what the previous list did; it
    /// was wrong because its entries were wrong, not because pinning is.
    private static let pinnedMIMETypes: [String: String] = [
        // Images
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "png": "image/png",
        "gif": "image/gif",
        "svg": "image/svg+xml",
        // Documents
        "pdf": "application/pdf",
        "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        // IANA registers application/rtf; it is also what MSGParser emits for
        // a pass-through RTF body, so the two agree within SwiftMail.
        "rtf": "application/rtf",
        // Text
        "txt": "text/plain",
        "html": "text/html",
        "htm": "text/html",
        "csv": "text/csv",
        "json": "application/json",
        "xml": "application/xml",
        "md": "text/markdown",
        "markdown": "text/markdown",
        // Archives and mail
        "zip": "application/zip",
        "eml": "message/rfc822",
        "ics": "text/calendar"
    ]

    /// The MIME type for a file extension, falling back to
    /// `application/octet-stream` — callers can always pass `mimeType:`
    /// explicitly.
    ///
    /// Pinned types come first and are the same everywhere. Anything else is
    /// answered by `UTType`, which covers far more extensions than a
    /// hand-written list can but whose answers for the long tail may differ
    /// between Apple and non-Apple platforms.
    ///
    /// The lookup this replaced was pinned-only and had gone stale in the
    /// silent direction: a missing or wrong entry still produces a *plausible*
    /// Content-Type, never an error, so it surfaced only when a recipient's
    /// client trusted the header over the filename. `.docx` and `.xlsx` were
    /// declared as their pre-2007 equivalents, and anything unlisted — `.csv`,
    /// `.pptx`, `.json` — came out as `application/octet-stream`.
    static func mimeType(for pathExtension: String) -> String {
        let normalized = pathExtension.lowercased()
        return pinnedMIMETypes[normalized]
            ?? UTType(filenameExtension: normalized)?.preferredMIMEType
            ?? "application/octet-stream"
    }
}
