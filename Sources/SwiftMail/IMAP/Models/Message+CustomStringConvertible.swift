// Message+CustomStringConvertible.swift
// CustomStringConvertible extension for Email

import Foundation

/// Standard description - simple and concise
extension Message: CustomStringConvertible {
    public var description: String {
        let subjectStr = subject ?? "No subject"
        let fromStr = from ?? "No sender"
        let subjectPart = subjectStr.truncated(maxLength: 50)
        let fromPart = fromStr.truncated(maxLength: 30)
        return "Email #\(sequenceNumber) | \(subjectPart) | From: \(fromPart)"
    }
}

/// Helper extension to truncate strings for display
private extension String {
    func truncated(maxLength: Int) -> String {
        if count <= maxLength {
            return self
        }
        let endIndex = index(startIndex, offsetBy: maxLength - 3)
        return String(self[..<endIndex]) + "..."
    }
}
