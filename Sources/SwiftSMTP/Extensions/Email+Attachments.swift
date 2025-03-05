// Email+Attachments.swift
// Extension for Email to add convenience methods for attachments

import Foundation

public extension Email {
    /**
     Create a new email with an additional attachment
     - Parameters:
        - attachment: The attachment to add
     - Returns: A new Email instance with the attachment added
     */
    func addingAttachment(_ attachment: Attachment) -> Email {
        var newAttachments = self.attachments ?? []
        newAttachments.append(attachment)
        
        return Email(
            sender: self.sender,
            recipients: self.recipients,
            subject: self.subject,
            textBody: self.textBody,
            htmlBody: self.htmlBody,
            attachments: newAttachments
        )
    }
    
    /**
     Create a new email with an additional file attachment
     - Parameters:
        - fileURL: The URL of the file to attach
        - mimeType: The MIME type of the attachment (if nil, will attempt to determine from file extension)
        - contentID: Optional content ID for inline attachments
        - isInline: Whether this attachment should be displayed inline (default: false)
     - Returns: A new Email instance with the attachment added
     - Throws: An error if the file cannot be read
     */
    func addingAttachment(fileURL: URL, mimeType: String? = nil, contentID: String? = nil, isInline: Bool = false) throws -> Email {
        let attachment = try Attachment(fileURL: fileURL, mimeType: mimeType, contentID: contentID, isInline: isInline)
        return addingAttachment(attachment)
    }
    
    /**
     Create a new email with an additional inline image attachment
     - Parameters:
        - imageURL: The URL of the image file to attach
        - contentID: The content ID to use for referencing the image in HTML (if nil, will generate one)
     - Returns: A new Email instance with the inline image attachment added
     - Throws: An error if the file cannot be read
     */
    func addingInlineImage(imageURL: URL, contentID: String? = nil) throws -> Email {
        let generatedContentID = contentID ?? UUID().uuidString
        return try addingAttachment(fileURL: imageURL, contentID: generatedContentID, isInline: true)
    }
    
    /**
     Create a new email with multiple attachments added
     - Parameters:
        - attachments: The attachments to add
     - Returns: A new Email instance with the attachments added
     */
    func addingAttachments(_ attachments: [Attachment]) -> Email {
        var newAttachments = self.attachments ?? []
        newAttachments.append(contentsOf: attachments)
        
        return Email(
            sender: self.sender,
            recipients: self.recipients,
            subject: self.subject,
            textBody: self.textBody,
            htmlBody: self.htmlBody,
            attachments: newAttachments
        )
    }
    
    /**
     Create a new email with HTML body added or replaced
     - Parameters:
        - htmlBody: The HTML body to set
     - Returns: A new Email instance with the HTML body set
     */
    func withHTMLBody(_ htmlBody: String) -> Email {
        return Email(
            sender: self.sender,
            recipients: self.recipients,
            subject: self.subject,
            textBody: self.textBody,
            htmlBody: htmlBody,
            attachments: self.attachments
        )
    }
} 