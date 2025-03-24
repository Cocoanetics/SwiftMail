// Email.swift
// Common email model for email messages

import Foundation

/**
 A struct representing an email message
 */
public struct Email {
    /** The sender of the email */
    public var sender: EmailAddress
    
    /** The primary recipients of the email */
    public var recipients: [EmailAddress]
    
    /** The CC (Carbon Copy) recipients of the email */
    public var ccRecipients: [EmailAddress]
    
    /** The BCC (Blind Carbon Copy) recipients of the email */
    public var bccRecipients: [EmailAddress]
    
    /** The subject of the email */
    public var subject: String
    
    /** The plain text body of the email */
    public var textBody: String
    
    /** The HTML body of the email (optional) */
    public var htmlBody: String?
    
    /** Optional attachments for the email */
    public var attachments: [Attachment]?
    
    /**
     Initialize a new email with EmailAddress objects
     - Parameters:
     - sender: The sender of the email
     - recipients: The primary recipients of the email
     - ccRecipients: The CC (Carbon Copy) recipients of the email (optional)
     - bccRecipients: The BCC (Blind Carbon Copy) recipients of the email (optional)
     - subject: The subject of the email
     - textBody: The plain text body of the email
     - htmlBody: The HTML body of the email (optional)
     - attachments: Optional attachments for the email
     */
    public init(
        sender: EmailAddress,
        recipients: [EmailAddress],
        ccRecipients: [EmailAddress] = [],
        bccRecipients: [EmailAddress] = [],
        subject: String,
        textBody: String,
        htmlBody: String? = nil,
        attachments: [Attachment]? = nil
    ) {
        self.sender = sender
        self.recipients = recipients
        self.ccRecipients = ccRecipients
        self.bccRecipients = bccRecipients
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
    public init(senderName: String?, senderAddress: String, recipientNames: [String]?, recipientAddresses: [String], subject: String, textBody: String, htmlBody: String? = nil, attachments: [Attachment]? = nil) {
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
    
    /**
     Get all inline attachments from the email
     - Returns: An array of inline attachments, or an empty array if none
     */
    public var inlineAttachments: [Attachment] {
        guard let attachments = attachments else { return [] }
        return attachments.filter { $0.isInline }
    }
    
    /**
     Get all regular (non-inline) attachments from the email
     - Returns: An array of regular attachments, or an empty array if none
     */
    public var regularAttachments: [Attachment] {
        guard let attachments = attachments else { return [] }
        return attachments.filter { !$0.isInline }
    }
    
    /**
     Get all recipients (To, CC, and BCC) combined
     - Returns: An array of all recipients
     */
    public var allRecipients: [EmailAddress] {
        return recipients + ccRecipients + bccRecipients
    }
} 
