// Email+StringInitializers.swift
// Extension to Email to add convenience initializers and methods for working
// with string representations of email addresses

import Foundation

public extension Email {
    /**
     Initialize a new email with string-based sender and recipient information
     
     - Parameters:
        - senderString: The sender as a formatted string (e.g., "John Doe <john@example.com>")
        - recipientStrings: The recipients as formatted strings
        - ccRecipientStrings: The CC recipients as formatted strings (optional)
        - bccRecipientStrings: The BCC recipients as formatted strings (optional)
        - subject: The subject of the email
        - textBody: The plain text body of the email
        - htmlBody: The HTML body of the email (optional)
        - attachments: Optional attachments for the email

     Each string is one mailbox (see ``EmailAddress/init(_:)``). Returns `nil`
     if the sender or any recipient is not a valid address, rather than sending
     to fewer people than named, or if there are no recipients.
     */
    init?(
        senderString: String,
        recipientStrings: [String],
        ccRecipientStrings: [String] = [],
        bccRecipientStrings: [String] = [],
        subject: String,
        textBody: String,
        htmlBody: String? = nil,
        attachments: [Attachment]? = nil
    ) {
        guard let sender = EmailAddress(senderString),
              let recipients = Self.addresses(recipientStrings), !recipients.isEmpty,
              let ccRecipients = Self.addresses(ccRecipientStrings),
              let bccRecipients = Self.addresses(bccRecipientStrings) else {
            return nil
        }

        self.init(
            sender: sender,
            recipients: recipients,
            ccRecipients: ccRecipients,
            bccRecipients: bccRecipients,
            subject: subject,
            textBody: textBody,
            htmlBody: htmlBody,
            attachments: attachments
        )
    }

    /**
     Initialize a new email with string-based sender and a single recipient

     Returns `nil` if the sender or any recipient is not a valid address.
     
     - Parameters:
        - senderString: The sender as a formatted string (e.g., "John Doe <john@example.com>")
        - recipientString: The recipient as a formatted string
        - ccRecipientStrings: The CC recipients as formatted strings (optional)
        - bccRecipientStrings: The BCC recipients as formatted strings (optional)
        - subject: The subject of the email
        - textBody: The plain text body of the email
        - htmlBody: The HTML body of the email (optional)
        - attachments: Optional attachments for the email
     */
    init?(
        senderString: String,
        recipientString: String,
        ccRecipientStrings: [String] = [],
        bccRecipientStrings: [String] = [],
        subject: String,
        textBody: String,
        htmlBody: String? = nil,
        attachments: [Attachment]? = nil
    ) {
        self.init(
            senderString: senderString,
            recipientStrings: [recipientString],
            ccRecipientStrings: ccRecipientStrings,
            bccRecipientStrings: bccRecipientStrings,
            subject: subject,
            textBody: textBody,
            htmlBody: htmlBody,
            attachments: attachments
        )
    }

    /// The addresses of `strings`, one mailbox each, or `nil` if any of them isn't one.
    private static func addresses(_ strings: [String]) -> [EmailAddress]? {
        let addresses = strings.compactMap { EmailAddress($0) }
        return addresses.count == strings.count ? addresses : nil
    }
}
