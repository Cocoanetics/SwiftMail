import Foundation

// MARK: - CustomDebugStringConvertible

extension Email: CustomDebugStringConvertible {
    public var debugDescription: String {
        var description = "Email {\n"
        description += "  From: \(sender.formatted)\n"
        description += "  To: \(recipients.map { $0.formatted }.joined(separator: ", "))\n"
        description += "  Subject: \(subject)\n"
        description += "  Body: \(body.prefix(100))\(body.count > 100 ? "..." : "")\n"
        
        if let attachments = attachments, !attachments.isEmpty {
            description += "  Attachments: \(attachments.count) {\n"
            for attachment in attachments {
                description += "    \(attachment.filename) (\(attachment.mimeType), \(attachment.data.count) bytes)\n"
            }
            description += "  }\n"
        }
        
        description += "}"
        return description
    }
} 