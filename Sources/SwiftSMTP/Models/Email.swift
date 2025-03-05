// Email.swift
// Model representing an email message

import Foundation

/**
 A struct representing an email message
 */
public struct Email {
    /** The sender of the email */
    public let sender: EmailAddress
    
    /** The recipients of the email */
    public let recipients: [EmailAddress]
    
    /** The subject of the email */
    public let subject: String
    
    /** The plain text body of the email */
    public let textBody: String
    
    /** The HTML body of the email (optional) */
    public let htmlBody: String?
    
    /** Optional attachments for the email */
    public let attachments: [Attachment]?
    
    /**
     Initialize a new email with EmailAddress objects
     - Parameters:
     - sender: The sender of the email
     - recipients: The recipients of the email
     - subject: The subject of the email
     - textBody: The plain text body of the email
     - htmlBody: The HTML body of the email (optional)
     - attachments: Optional attachments for the email
     */
    public init(sender: EmailAddress, recipients: [EmailAddress], subject: String, textBody: String, htmlBody: String? = nil, attachments: [Attachment]? = nil) {
        self.sender = sender
        self.recipients = recipients
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
    }
    
    /**
     Initialize a new email with string-based sender and recipient information
     - Parameters:
     - senderName: The name of the sender (optional)
     - senderAddress: The email address of the sender
     - recipientNames: The names of the recipients (optional)
     - recipientAddresses: The email addresses of the recipients
     - subject: The subject of the email
     - textBody: The plain text body of the email
     - htmlBody: The HTML body of the email (optional)
     - attachments: Optional attachments for the email
     */
    public init(senderName: String? = nil, senderAddress: String, recipientNames: [String?]? = nil, recipientAddresses: [String], subject: String, textBody: String, htmlBody: String? = nil, attachments: [Attachment]? = nil) {
        // Create sender EmailAddress
        let sender = EmailAddress(name: senderName, address: senderAddress)
        
        // Create recipient EmailAddress objects
        var recipients: [EmailAddress] = []
        
        if let recipientNames = recipientNames, recipientNames.count == recipientAddresses.count {
            // If recipient names are provided and count matches addresses
            for i in 0..<recipientAddresses.count {
                let recipient = EmailAddress(name: recipientNames[i], address: recipientAddresses[i])
                recipients.append(recipient)
            }
        } else {
            // If no recipient names are provided or count doesn't match
            for address in recipientAddresses {
                let recipient = EmailAddress(name: nil, address: address)
                recipients.append(recipient)
            }
        }
        
        // Initialize with the created objects
        self.init(sender: sender, recipients: recipients, subject: subject, textBody: textBody, htmlBody: htmlBody, attachments: attachments)
    }
} 
