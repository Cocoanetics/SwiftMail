// Email+CustomStringConvertible.swift
// CustomStringConvertible extension for Email

import Foundation

// Standard description - simple and concise
extension Message: CustomStringConvertible {
    public var description: String {
        let subjectStr = subject ?? "No subject"
        let fromStr = from ?? "No sender"
        let truncatedSubject = subjectStr.truncated(maxLength: 50)
        let truncatedFrom = fromStr.truncated(maxLength: 30)
        return "Email #\(sequenceNumber) | \(truncatedSubject) | From: \(truncatedFrom)"
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
