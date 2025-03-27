// Message.swift
// Structure to represent a complete email with all parts

import Foundation

/// Structure to represent a complete email with all parts
public struct Message: Codable, Sendable {
    /// The email header information
    public let header: Header
    
    /// The UID of the message
    public var uid: Int {
        return header.uid
    }
    
    /// The sequence number of the message
    public var sequenceNumber: Int {
        return header.sequenceNumber
    }
    
    /// The subject of the message
    public var subject: String {
        return header.subject
    }
    
    /// The sender of the message
    public var from: String {
        return header.from
    }
    
    /// The recipients of the message
    public var to: String {
        return header.to
    }
    
    /// The CC recipients of the message
    public var cc: String {
        return header.cc
    }
    
    /// The date of the message
    public var date: Date {
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
    
    /// The size of the email in bytes
    public var size: Int {
        return parts.reduce(0) { $0 + $1.size }
    }
    
    /// Initialize a new email
    /// - Parameters:
    ///   - header: The email header
    ///   - parts: The message parts
    public init(header: Header, parts: [MessagePart]) {
        self.header = header
        self.parts = parts
    }
    
    /// Find the plain text body of the email
    /// - Returns: The plain text body, or nil if not found
    private func findTextBody() -> String? {
        // First look for a part with content type "text/plain" that is not an attachment
        for part in parts where part.contentType.lowercased() == "text" && 
                               part.contentSubtype.lowercased() == "plain" && 
                               part.disposition?.lowercased() != "attachment" {
            guard let text = String(data: part.data, encoding: .utf8) else {
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
        for part in parts where part.contentType.lowercased() == "text" {
            guard let text = String(data: part.data, encoding: .utf8) else {
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
    /// - Returns: The HTML body, or nil if not found
    private func findHtmlBody() -> String? {
        // Look for a part with content type "text/html" that is not an attachment
        for part in parts where part.contentType.lowercased() == "text" && 
                               part.contentSubtype.lowercased() == "html" && 
                               part.disposition?.lowercased() != "attachment" {
            guard let text = String(data: part.data, encoding: .utf8) else {
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
    
    /// Decode QUOTED-PRINTABLE encoded data
    /// - Parameter data: The QUOTED-PRINTABLE encoded data
    /// - Returns: The decoded string, or nil if decoding fails
    private func decodeQuotedPrintable(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        // Replace common QUOTED-PRINTABLE encodings
        let decoded = text
            .replacingOccurrences(of: "=\r\n", with: "") // Remove soft line breaks
            .replacingOccurrences(of: "=20", with: " ")  // Space
            .replacingOccurrences(of: "=09", with: "\t") // Tab
            .replacingOccurrences(of: "=0A", with: "\n") // Line feed
            .replacingOccurrences(of: "=0D", with: "\r") // Carriage return
            .replacingOccurrences(of: "=3D", with: "=")  // Equals sign
            .replacingOccurrences(of: "=22", with: "\"") // Double quote
            .replacingOccurrences(of: "=27", with: "'")  // Single quote
            .replacingOccurrences(of: "=28", with: "(")  // Left parenthesis
            .replacingOccurrences(of: "=29", with: ")")  // Right parenthesis
            .replacingOccurrences(of: "=2C", with: ",")  // Comma
            .replacingOccurrences(of: "=2E", with: ".")  // Period
            .replacingOccurrences(of: "=2F", with: "/")  // Forward slash
            .replacingOccurrences(of: "=3A", with: ":")  // Colon
            .replacingOccurrences(of: "=3B", with: ";")  // Semicolon
            .replacingOccurrences(of: "=3C", with: "<")  // Less than
            .replacingOccurrences(of: "=3E", with: ">")  // Greater than
            .replacingOccurrences(of: "=40", with: "@")  // At symbol
            .replacingOccurrences(of: "=5B", with: "[")  // Left bracket
            .replacingOccurrences(of: "=5C", with: "\\") // Backslash
            .replacingOccurrences(of: "=5D", with: "]")  // Right bracket
            .replacingOccurrences(of: "=5E", with: "^")  // Caret
            .replacingOccurrences(of: "=5F", with: "_")  // Underscore
            .replacingOccurrences(of: "=60", with: "`")  // Backtick
            .replacingOccurrences(of: "=7B", with: "{")  // Left brace
            .replacingOccurrences(of: "=7C", with: "|")  // Vertical bar
            .replacingOccurrences(of: "=7D", with: "}")  // Right brace
            .replacingOccurrences(of: "=7E", with: "~")  // Tilde
        
        return decoded
    }
    
    /// Find all attachments in the email
    /// - Returns: An array of message parts that are attachments
    private func findAttachments() -> [MessagePart] {
        // Look for parts with disposition "attachment" or filename
        return parts.filter { part in
            (part.disposition?.lowercased() == "attachment") || 
            (part.filename != nil && !part.filename!.isEmpty)
        }
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

