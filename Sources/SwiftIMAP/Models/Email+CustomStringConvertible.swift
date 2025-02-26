// Email+CustomStringConvertible.swift
// CustomStringConvertible extension for Email

import Foundation

// Standard description - simple and concise
extension Email: CustomStringConvertible {
    public var description: String {
        return "Email #\(sequenceNumber) | \(subject.truncated(maxLength: 50)) | From: \(from.truncated(maxLength: 30))"
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