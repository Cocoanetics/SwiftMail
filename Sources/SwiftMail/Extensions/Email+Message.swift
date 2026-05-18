// Email+Message.swift
// Extension to convert a Message (IMAP) to an Email (SMTP)

import Foundation

/// Errors that can occur during Message ↔ Email model conversion.
public enum ConversionError: Error, Equatable, CustomStringConvertible {
    /// The message has no `from` field.
    case missingSender
    /// The `from` string could not be parsed into an `EmailAddress`.
    case unparsableSender(String)

    public var description: String {
        switch self {
        case .missingSender:
            return "Message has no sender (from field is nil)"
        case .unparsableSender(let raw):
            return "Could not parse sender address: \(raw)"
        }
    }
}

extension Email {
    /// Initialize an `Email` from an IMAP `Message`.
    ///
    /// - Parameter message: The IMAP message to convert.
    /// - Throws: `ConversionError.missingSender` if the message has no `from` field,
    ///           `ConversionError.unparsableSender` if the `from` string cannot be parsed.
    public init(message: Message) throws {
        guard let fromStr = message.from else {
            throw ConversionError.missingSender
        }
        guard let sender = EmailAddress(fromStr) else {
            throw ConversionError.unparsableSender(fromStr)
        }

        let recipients = message.to.compactMap { EmailAddress($0) }
        let ccRecipients = message.cc.compactMap { EmailAddress($0) }
        let bccRecipients = message.bcc.compactMap { EmailAddress($0) }

        // Explicit attachments from the message
        let attachmentParts = message.attachments

        // CID-referenced inline parts not already in the attachments list
        let attachmentSections = Set(attachmentParts.map { $0.section })
        let cidParts = message.cids.filter { !attachmentSections.contains($0.section) }

        var allAttachments: [Attachment] = []

        for part in attachmentParts {
            guard let data = part.decodedData() else { continue }
            allAttachments.append(Attachment(
                filename: part.filename ?? part.suggestedFilename,
                mimeType: part.contentType,
                data: data,
                contentID: part.contentId,
                isInline: part.disposition?.lowercased() == "inline"
            ))
        }

        for part in cidParts {
            guard let data = part.decodedData() else { continue }
            allAttachments.append(Attachment(
                filename: part.filename ?? part.suggestedFilename,
                mimeType: part.contentType,
                data: data,
                contentID: part.contentId,
                isInline: true
            ))
        }

        // Skip standard headers already captured via dedicated fields
        let standardHeaders: Set<String> = [
            "Subject", "From", "To", "Cc", "Bcc",
            "Message-ID", "References", "In-Reply-To", "Date"
        ]
        let additionalHeaders = message.header.additionalFields?
            .filter { !standardHeaders.contains($0.key) }

        self.init(
            sender: sender,
            recipients: recipients,
            ccRecipients: ccRecipients,
            bccRecipients: bccRecipients,
            subject: message.subject ?? "",
            textBody: message.textBody ?? "",
            htmlBody: message.htmlBody,
            attachments: allAttachments.isEmpty ? nil : allAttachments
        )
        self.messageID = message.header.messageId
        self.additionalHeaders = (additionalHeaders?.isEmpty == false) ? additionalHeaders : nil
    }
}
