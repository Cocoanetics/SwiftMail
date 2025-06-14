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
    public var to: String? {
        return header.to
    }
    
    /// The CC recipients of the message
    public var cc: String? {
        return header.cc
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
        return findTextBody()
    }
    
    /// The HTML body of the email (if available)
    public var htmlBody: String? {
        return findHtmlBody()
    }
    
    /// All attachments in the email
    public var attachments: [MessagePart] {
        return findAttachments()
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
    /// Find the plain text body of the email
    /// - Returns: The plain text body, or `nil` if not found
    func findTextBody() -> String? {
        // First look for a part with content type "text/plain" that is not an attachment
        for part in parts where part.contentType.lowercased() == "text/plain" &&
            part.disposition?.lowercased() != "attachment" {
                guard let partData = part.data,
                      let text = String(data: partData, encoding: .utf8) else {
                    continue
                }

                let decodedText = part.encoding?.lowercased() == "quoted-printable" ?
                    text.decodeQuotedPrintable() :
                    text

                if let decodedText = decodedText {
                    return decodedText
                }
        }

        // If not found, look for any text part
        for part in parts where part.contentType.lowercased().hasPrefix("text/") {
            guard let partData = part.data,
                  let text = String(data: partData, encoding: .utf8) else {
                continue
            }

            let decodedText = part.encoding?.lowercased() == "quoted-printable" ?
                text.decodeQuotedPrintable() :
                text

            if let decodedText = decodedText {
                return decodedText
            }
        }

        return nil
    }

    /// Find the HTML body of the email
    /// - Returns: The HTML body, or `nil` if not found
    func findHtmlBody() -> String? {
        // Look for a part with content type "text/html" that is not an attachment
        for part in parts where part.contentType.lowercased() == "text/html" &&
            part.disposition?.lowercased() != "attachment" {
                guard let partData = part.data,
                      let text = String(data: partData, encoding: .utf8) else {
                    continue
                }

                let decodedHtml = part.encoding?.lowercased() == "quoted-printable" ?
                    text.decodeQuotedPrintable() :
                    text

                if let decodedHtml = decodedHtml {
                    return decodedHtml
                }
        }

        return nil
    }

    /// Find all attachments in the email
    /// - Returns: An array of message parts that are attachments
    func findAttachments() -> [MessagePart] {
        // Look for parts with disposition "attachment" or filename
        return parts.filter { part in
            (part.disposition?.lowercased() == "attachment") ||
            (part.filename != nil && !part.filename!.isEmpty)
        }
    }
}

