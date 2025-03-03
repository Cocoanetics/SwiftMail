// Email+CustomDebugStringConvertible.swift
// CustomDebugStringConvertible extension for Email

import Foundation

// Detailed debug description - comprehensive information for debugging
extension Email: CustomDebugStringConvertible {
    public var debugDescription: String {
        // Compact header information
        let headerInfo = """
        Email #\(sequenceNumber) (UID: \(uid)) | \(date.formattedForDisplay())
        From: \(from.truncated(maxLength: 100))
        To: \(to.truncated(maxLength: 100))
        Subject: \(subject.truncated(maxLength: 200))
        """
        
        // Build the complete debug description
        var debugInfo = headerInfo
        
        // Add content type indicators with checkmarks
        var contentTypes = [String]()
        
        // Check for plain text part
        if parts.contains(where: { $0.contentType.lowercased() == "text" && $0.contentSubtype.lowercased() == "plain" }) {
            contentTypes.append("✓ Plain")
        }
        
        // Check for HTML part
        if parts.contains(where: { $0.contentType.lowercased() == "text" && $0.contentSubtype.lowercased() == "html" }) {
            contentTypes.append("✓ HTML")
        }
        
        // Add content type indicators if any are present
        if !contentTypes.isEmpty {
            debugInfo += "\n\(contentTypes.joined(separator: " | "))"
        }
        
        // Add attachment information if there are attachments
        if !attachments.isEmpty {
            let attachmentsInfo = attachments.map { attachment -> String in
                let filename = attachment.filename ?? "unnamed"
                let mimeType = "\(attachment.contentType)/\(attachment.contentSubtype)"
                let size = attachment.size.formattedFileSize()
                let id = attachment.contentId ?? "no-id"
                
                return "- \(filename.truncated(maxLength: 30)) | \(mimeType) | \(size) | ID: \(id.truncated(maxLength: 15))"
            }.joined(separator: "\n")
            
            debugInfo += "\n\nAttachments:\n\(attachmentsInfo)"
        }
        
//        // Add preview of the email content
//        let textPreview = preview(maxLength: 200).trimmingCharacters(in: .whitespacesAndNewlines)
//        if !textPreview.isEmpty {
//            debugInfo += "\n\n\(textPreview)"
//        }
        
        return debugInfo
    }

    /// Format the date for display
    private func formatDate() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.locale = Locale.current
        return formatter.string(from: date)
    }
}

// Helper extension to truncate strings for display
private extension String {
    func truncated(maxLength: Int) -> String {
        if self.count <= maxLength {
            return self
        }
        let endIndex = self.index(self.startIndex, offsetBy: maxLength - 3)
        return String(self[..<endIndex]) + "..."
    }
} 
