// Message+Email.swift
// Extension to convert an Email (SMTP) to a Message (IMAP)

import Foundation

extension Message {
    /// Initialize a `Message` from an `Email` for local preview or storage.
    ///
    /// Part data is stored raw (not transfer-encoded).
    /// `MessagePart.decodedData()` handles decoding based on the `encoding` field.
    ///
    /// - Parameter email: The email to convert.
    public init(email: Email) {
        var parts: [MessagePart] = []
        var nextSection = 1

        if !email.textBody.isEmpty {
            parts.append(MessagePart(
                sectionString: String(nextSection),
                contentType: "text/plain",
                disposition: "inline",
                encoding: "quoted-printable",
                data: email.textBody.data(using: .utf8)
            ))
            nextSection += 1
        }

        if let htmlBody = email.htmlBody, !htmlBody.isEmpty {
            parts.append(MessagePart(
                sectionString: String(nextSection),
                contentType: "text/html",
                disposition: "inline",
                encoding: "quoted-printable",
                data: htmlBody.data(using: .utf8)
            ))
            nextSection += 1
        }

        for att in email.attachments ?? [] {
            parts.append(MessagePart(
                sectionString: String(nextSection),
                contentType: att.mimeType,
                disposition: att.isInline ? "inline" : "attachment",
                encoding: "base64",
                filename: att.filename,
                contentId: att.contentID,
                data: att.data
            ))
            nextSection += 1
        }

        let header = MessageInfo(
            sequenceNumber: SequenceNumber(0),
            subject: email.subject,
            from: email.sender.description,
            to: email.recipients.map { $0.description },
            cc: email.ccRecipients.map { $0.description },
            bcc: email.bccRecipients.map { $0.description },
            messageId: email.messageID,
            additionalFields: email.additionalHeaders
        )

        self.init(header: header, parts: parts)
    }
}
