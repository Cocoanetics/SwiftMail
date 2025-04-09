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
            // Try to determine MIME type from file extension
            let pathExtension = fileURL.pathExtension.lowercased()
            switch pathExtension {
            case "jpg", "jpeg":
                self.mimeType = "image/jpeg"
            case "png":
                self.mimeType = "image/png"
            case "gif":
                self.mimeType = "image/gif"
            case "svg":
                self.mimeType = "image/svg+xml"
            case "pdf":
                self.mimeType = "application/pdf"
            case "txt":
                self.mimeType = "text/plain"
            case "html", "htm":
                self.mimeType = "text/html"
            case "doc", "docx":
                self.mimeType = "application/msword"
            case "xls", "xlsx":
                self.mimeType = "application/vnd.ms-excel"
            case "zip":
                self.mimeType = "application/zip"
            default:
                self.mimeType = "application/octet-stream"
            }
        }
        
        // Read the file data
        self.data = try Data(contentsOf: fileURL)
        
        // Set content ID and inline flag
        self.contentID = contentID
        self.isInline = isInline
    }
} 
