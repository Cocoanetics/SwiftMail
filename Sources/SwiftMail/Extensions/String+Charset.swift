// String+Charset.swift
// Charset-name → String.Encoding resolution.
//
// Backed by SwiftCross's `String.Encoding(ianaCharsetName:)`, which uses
// CoreFoundation's IANA table on Apple platforms and a built-in table
// elsewhere (with the same normalization/alias folding this used to do inline).

import SwiftCross

/// Resolve a charset label (e.g. "utf-8", "ISO-8859-1", "windows-1252", "cp932")
/// to a `String.Encoding`. Returns `nil` if unknown or not text (e.g. "binary").
public func stringEncoding(for rawCharset: String) -> String.Encoding? {
    String.Encoding(ianaCharsetName: rawCharset)
}

extension String {
    /// Convert a charset name to a Swift Encoding with robust normalization
    /// - Parameter charset: The charset name to convert
    /// - Returns: The corresponding String.Encoding, or .utf8 if not recognized
    static func encodingFromCharset(_ charset: String) -> String.Encoding {
        String.Encoding(ianaCharsetName: charset) ?? .utf8
    }
}
