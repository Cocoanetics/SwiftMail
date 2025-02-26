// MIMEHeaderDecoder.swift
// Utility functions for decoding MIME-encoded email headers

import Foundation

/// Utility functions for decoding MIME-encoded email headers
/// These functions have been moved to String extensions in String+QuotedPrintable.swift
@available(*, deprecated, message: "Use String extension methods instead")
enum MIMEHeaderDecoder {
    /// Decode a MIME-encoded header string
    /// - Parameter encodedString: The MIME-encoded string to decode
    /// - Returns: The decoded string
    @available(*, deprecated, message: "Use String.decodeMIMEHeader() instead")
    static func decode(_ encodedString: String) -> String {
        return encodedString.decodeMIMEHeader()
    }
    
    /// Decode quoted-printable content in message bodies
    /// - Parameter content: The content to decode
    /// - Returns: The decoded content
    @available(*, deprecated, message: "Use String.decodeQuotedPrintableContent() instead")
    public static func decodeQuotedPrintableContent(_ content: String) -> String {
        return content.decodeQuotedPrintableContent()
    }
} 