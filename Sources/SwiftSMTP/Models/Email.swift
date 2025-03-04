// Email.swift
// Model representing an email message

import Foundation

/**
 Represents an email message with sender, recipients, subject, and body
 */
public struct Email {
    /// The sender of the email
    public let sender: EmailAddress
    
    /// The recipients of the email
    public let recipients: [EmailAddress]
    
    /// The subject of the email
    public let subject: String
    
    /// The body of the email
    public let body: String
    
    /// Optional attachments for the email
    public let attachments: [Attachment]?
    
    /**
     Initialize a new email
     - Parameters:
     - sender: The sender of the email
     - recipients: The recipients of the email
     - subject: The subject of the email
     - body: The body of the email
     - attachments: Optional attachments for the email
     */
    public init(sender: EmailAddress, recipients: [EmailAddress], subject: String, body: String, attachments: [Attachment]? = nil) {
        self.sender = sender
        self.recipients = recipients
        self.subject = subject
        self.body = body
        self.attachments = attachments
    }
    
    /**
     Initialize a new email with string-based sender and recipients
     - Parameters:
     - sender: The name of the sender (optional)
     - senderAddress: The email address of the sender
     - recipients: The email addresses of the recipients
     - subject: The subject of the email
     - body: The body of the email
     - attachments: Optional attachments for the email
     */
    public init(sender: String?, senderAddress: String, recipients: [String], subject: String, body: String, attachments: [Attachment]? = nil) {
        // Create sender EmailAddress
        let senderEmailAddress = EmailAddress(name: sender, address: senderAddress)
        
        // Create recipient EmailAddresses
        let recipientEmailAddresses = recipients.map { EmailAddress(address: $0) }
        
        // Call the main initializer
        self.init(sender: senderEmailAddress, recipients: recipientEmailAddresses, subject: subject, body: body, attachments: attachments)
    }
}

/**
 Represents an attachment in an email
 */
public struct Attachment {
    /// The filename of the attachment
    public let filename: String
    
    /// The MIME type of the attachment
    public let mimeType: String
    
    /// The data of the attachment
    public let data: Data
    
    /**
     Initialize a new attachment
     - Parameters:
     - filename: The filename of the attachment
     - mimeType: The MIME type of the attachment
     - data: The data of the attachment
     */
    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
} 