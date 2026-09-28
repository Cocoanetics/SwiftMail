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
    /// Each address field may name several mailboxes and groups; the sender is
    /// the first mailbox of `from`, and group members are recipients like any
    /// other. Text that is not an address is left out.
    ///
    /// - Parameter message: The IMAP message to convert.
    /// - Throws: `ConversionError.missingSender` if the message has no `from` field,
    ///           `ConversionError.unparsableSender` if the `from` string names no mailbox.
    public init(message: Message) throws {
        guard let fromStr = message.from else {
            throw ConversionError.missingSender
        }
        guard let sender = Self.mailboxes(in: [fromStr]).first else {
            throw ConversionError.unparsableSender(fromStr)
        }

        let allAttachments = Self.collectAttachments(from: message)
        let additionalHeaders = Self.nonStandardHeaders(from: message)

        self.init(
            sender: sender,
            recipients: Self.mailboxes(in: message.to),
            ccRecipients: Self.mailboxes(in: message.cc),
            bccRecipients: Self.mailboxes(in: message.bcc),
            subject: message.subject ?? "",
            textBody: message.textBody ?? "",
            htmlBody: message.htmlBody,
            attachments: allAttachments.isEmpty ? nil : allAttachments
        )
        self.messageID = message.header.messageId
        self.additionalHeaders = (additionalHeaders?.isEmpty == false) ? additionalHeaders : nil
    }

    /// The mailboxes named by address field values, groups flattened to their members.
    private static func mailboxes(in fields: [String]) -> [EmailAddress] {
        fields.flatMap { AddressParser.parseAddressList($0).mailboxes }
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
