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

        let allAttachments = Self.collectAttachments(from: message)
        let additionalHeaders = Self.nonStandardHeaders(from: message)

        self.init(
            sender: sender,
            recipients: message.to.compactMap { EmailAddress($0) },
            ccRecipients: message.cc.compactMap { EmailAddress($0) },
            bccRecipients: message.bcc.compactMap { EmailAddress($0) },
            subject: message.subject ?? "",
            textBody: message.textBody ?? "",
            htmlBody: message.htmlBody,
            attachments: allAttachments.isEmpty ? nil : allAttachments
        )
        self.messageID = message.header.messageId
        self.additionalHeaders = (additionalHeaders?.isEmpty == false) ? additionalHeaders : nil
    }

    /// Collect explicit attachments plus any CID-referenced inline parts not already
    /// included in the attachments list, turning each into an ``Attachment``.
    private static func collectAttachments(from message: Message) -> [Attachment] {
        let attachmentParts = message.attachments
        let attachmentSections = Set(attachmentParts.map { $0.section })
        let cidParts = message.cids.filter { !attachmentSections.contains($0.section) }

        var attachments: [Attachment] = []
        for part in attachmentParts {
            guard let data = part.decodedData() else { continue }
            attachments.append(Attachment(
                filename: part.filename ?? part.suggestedFilename,
                mimeType: part.contentType,
                data: data,
                contentID: part.contentId,
                isInline: part.disposition?.lowercased() == "inline"
            ))
        }
        for part in cidParts {
            guard let data = part.decodedData() else { continue }
            attachments.append(Attachment(
                filename: part.filename ?? part.suggestedFilename,
                mimeType: part.contentType,
                data: data,
                contentID: part.contentId,
                isInline: true
            ))
        }
        return attachments
    }

    /// Skip standard headers already captured via dedicated fields.
    private static func nonStandardHeaders(from message: Message) -> [String: String]? {
        let standardHeaders: Set<String> = [
            "Subject", "From", "To", "Cc", "Bcc",
            "Message-ID", "References", "In-Reply-To", "Date"
        ]
        return message.header.additionalFields?.filter { !standardHeaders.contains($0.key) }
    }
}
