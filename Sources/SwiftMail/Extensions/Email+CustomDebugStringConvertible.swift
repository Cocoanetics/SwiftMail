// Email+CustomDebugStringConvertible.swift
// Extension for Email to add debug description

import Foundation

// MARK: - CustomDebugStringConvertible

extension Email: CustomDebugStringConvertible {
    public var debugDescription: String {
        var description = "Email {\n"
        description += "  From: \(sender)\n"
        description += "  To: \(recipients.map(\.description).joined(separator: ", "))\n"
        description += "  Subject: \(subject)\n"
        description += "  Text Body: \(textBody.prefix(100))\(textBody.count > 100 ? "..." : "")\n"

        if let htmlBody {
            description += "  HTML Body: \(htmlBody.prefix(100))\(htmlBody.count > 100 ? "..." : "")\n"
        }

        if let attachments, !attachments.isEmpty {
            description += "  Attachments: \(attachments.count) {\n"
            for attachment in attachments {
                let inlineStatus = attachment.isInline ? " (inline)" : ""
                let contentIDInfo = attachment.contentID != nil ? " contentID: \(attachment.contentID!)" : ""
                let header = "    \(attachment.filename)"
                    + " (\(attachment.mimeType), \(attachment.data.count) bytes)"
                description += "\(header)\(inlineStatus)\(contentIDInfo)\n"
            }
            description += "  }\n"
        }

        description += "}"
        return description
    }
}
