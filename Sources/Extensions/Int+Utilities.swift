// Int+Utilities.swift
// Extensions for Int to handle IMAP-related utilities

import Foundation

extension Int {
    /// Format a file size in bytes to a human-readable string
    /// - Returns: A formatted string (e.g., "1.2 KB")
    func formattedFileSize() -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(self))
    }
} 