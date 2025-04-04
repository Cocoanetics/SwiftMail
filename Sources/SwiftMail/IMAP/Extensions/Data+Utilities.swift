// Data+Utilities.swift
// Extensions for Data to handle MIME-related utilities

import Foundation

extension Data {
    /// Create a preview of the data content
    /// - Parameter maxLength: The maximum length of the preview
    /// - Returns: A string preview of the content
    func preview(maxLength: Int = 500) -> String {
        if let text = String(data: self, encoding: .utf8) {
            let truncated = text.prefix(maxLength)
            return String(truncated)
        } else if self.count > 0 {
            return "<Binary data: \(self.count.formattedFileSize())>"
        } else {
            return "<Empty data>"
        }
    }
    
    /// Check if the data appears to be text content
    /// - Returns: True if the data appears to be text, false otherwise
    func isTextContent() -> Bool {
        // Check if the data can be converted to a string
        guard let _ = String(data: self, encoding: .utf8) else {
            return false
        }
        
        // Check for common binary file signatures
        if self.count >= 4 {
            let bytes = [UInt8](self.prefix(4))
            
            // Check for common binary file signatures
            if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { // JPEG
                return false
            }
            if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { // PNG
                return false
            }
            if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { // GIF
                return false
            }
            if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) { // PDF
                return false
            }
            if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { // ZIP
                return false
            }
        }
        
        return true
    }
} 
