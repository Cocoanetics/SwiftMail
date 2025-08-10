// Email+CustomDebugStringConvertible.swift
// CustomDebugStringConvertible extension for Email

import Foundation

// Detailed debug description - comprehensive information for debugging
extension Message: CustomDebugStringConvertible {
    public var debugDescription: String {
        // Format date safely
        let dateString = date?.formattedForDisplay() ?? "No date"
        
        // Safely unwrap other optional values
        let fromString = from ?? "No sender"
        let toString = to.isEmpty ? "No recipients" : to.joined(separator: ", ")
        let subjectString = subject ?? "No subject"
        
        // Compact header information
        let headerInfo = """
        Email #\(sequenceNumber) (UID: \(String(describing: uid)) | \(dateString)
        From: \(fromString.truncated(maxLength: 100))
        To: \(toString.truncated(maxLength: 100))
        Subject: \(subjectString.truncated(maxLength: 200))
        Flags: \(flags.isEmpty ? "none" : flags.map(String.init(describing:)).sorted().joined(separator: " "))
        """
        
        // Build the complete debug description
        var debugInfo = headerInfo
        
        // Add content type indicators with checkmarks
        var contentTypes = [String]()
        
        // Check for plain text part
        if parts.contains(where: { $0.contentType.lowercased() == "text/plain" }) {
            contentTypes.append("✓ Plain")
        }
        
        // Check for HTML part
        if parts.contains(where: { $0.contentType.lowercased() == "text/html" }) {
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
                let mimeType = attachment.contentType
                let id = attachment.contentId ?? "no-id"
                
                return "- \(filename.truncated(maxLength: 30)) | \(mimeType) | ID: \(id.truncated(maxLength: 15))"
            }.joined(separator: "\n")
            
            debugInfo += "\n\nAttachments:\n\(attachmentsInfo)"
        }
        
        return debugInfo
    }

    /// Format the date for display
    private func formatDate() -> String {
        guard let date = date else {
            return "No date"
        }
        
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
