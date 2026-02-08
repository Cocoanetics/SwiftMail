// Message.swift
// Defines the `Message` type used to represent a complete email.

import Foundation

/// Represents a complete email message including headers and parts.
public struct Message: Codable, Sendable {
    /// The email header information
    public let header: MessageInfo
    
    /// The UID of the message
    public var uid: UID? {
        return header.uid
    }
    
    /// The sequence number of the message
    public var sequenceNumber: SequenceNumber {
        return header.sequenceNumber
    }
    
    /// The subject of the message
    public var subject: String? {
        return header.subject
    }
    
    /// The sender of the message
    public var from: String? {
        return header.from
    }
    
    /// The recipients of the message
    public var to: [String] {
        return header.to
    }

    /// The CC recipients of the message
    public var cc: [String] {
        return header.cc
    }

    /// The BCC recipients of the message
    public var bcc: [String] {
        return header.bcc
    }

    /// The date of the message
    public var date: Date? {
        return header.date
    }
    
    /// The flags of the message
    public var flags: [Flag] {
        return header.flags
    }
    
    /// All message parts
    public let parts: [MessagePart]
    
    /// The plain text body of the email (if available)
    public var textBody: String? {
        return bodyContent(for: "text/plain")
    }
    
    /// The HTML body of the email (if available)
    public var htmlBody: String? {
        return bodyContent(for: "text/html")
    }
    
    /// All attachments in the email
    public var attachments: [MessagePart] {
        // Treat explicit attachments as attachments even if they have Content-ID.
        // Exclude inline parts that only have a filename.
        // Exclude parts with Content-ID but no explicit "attachment" disposition (they are CID references).
        return parts.filter { part in
            let disposition = part.disposition?.lowercased()
            let hasFilename = !(part.filename?.isEmpty ?? true)
            let isAttachment = disposition == "attachment"
            let isInline = disposition == "inline"
            let isCidOnly = part.contentId != nil && !isAttachment
            return isAttachment || (hasFilename && !isInline && !isCidOnly)
        }
    }

    /// All inline content referenced by Content-ID (CID)
    public var cids: [MessagePart] {
        return parts.filter { $0.contentId != nil }
    }
    
    /// All body parts in the email (text and HTML)
    public var bodies: [MessagePart] {
        return parts.filter { part in
            // Look for text parts that are not attachments
            part.contentType.lowercased().hasPrefix("text/") &&
            part.disposition?.lowercased() != "attachment"
        }
    }
    
    /// Initialize a new email
    /// - Parameters:
    ///   - header: The email header
    ///   - parts: The message parts
    public init(header: MessageInfo, parts: [MessagePart]) {
        self.header = header
        self.parts = parts
    }

    /// Get a formatted preview of the email content
    /// - Parameter maxLength: The maximum length of the preview
    /// - Returns: A string preview of the email content
    public func preview(maxLength: Int = 100) -> String {
        if let text = textBody?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let previewText = text.prefix(maxLength)
            if previewText.count < text.count {
                return String(previewText) + "..."
            }
            return String(previewText)
        }
        
        if let html = htmlBody {
            // Simple HTML to text conversion for preview
            let strippedHtml = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let previewText = strippedHtml.prefix(maxLength)
            if previewText.count < strippedHtml.count {
                return String(previewText) + "..."
            }
            return String(previewText)
        }
        
        return "No preview available"
    }
}

// MARK: - Helper Methods
private extension Message {
    
    /// Find body content of a specific type
    /// - Parameter type: The content type to search for (e.g., "text/plain", "text/html")
    /// - Returns: The body content, or `nil` if not found
    func bodyContent(for type: String) -> String? {
        // Find the first part with the exact content type in the bodies
        guard let part = bodies.first(where: { $0.contentType.lowercased().hasPrefix(type) }) else {
            return nil
        }
        
        return part.textContent
    }
}

// MARK: - Public Body Finding Extensions
public extension Message {
    /// Find the text body part
    /// - Returns: The text body part, or `nil` if not found
    func findTextBodyPart() -> MessagePart? {
        return bodies.first { $0.contentType.lowercased().hasPrefix("text/plain") }
    }
    
    /// Find the HTML body part
    /// - Returns: The HTML body part, or `nil` if not found
    func findHtmlBodyPart() -> MessagePart? {
        return bodies.first { $0.contentType.lowercased().hasPrefix("text/html") }
    }
}
