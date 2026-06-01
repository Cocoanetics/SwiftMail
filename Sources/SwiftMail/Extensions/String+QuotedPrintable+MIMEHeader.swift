// String+QuotedPrintable+MIMEHeader.swift
// MIME encoded-word header decoding and charset-aware decoding helpers split
// off from the main quoted-printable file.

import Foundation
import SwiftCross

extension String {
    /// Decode a MIME-encoded header string
    /// - Returns: The decoded string
    public func decodeMIMEHeader() -> String {
        let pattern = "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?="
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return self
        }
        let matches = regex.matches(in: self, options: [], range: NSRange(self.startIndex..., in: self))

        var state = MIMEHeaderDecodeState(
            lastIndex: self.startIndex,
            hasPreviousEncodedWord: false,
            pendingRun: nil,
            result: ""
        )

        for match in matches {
            String.processMIMEEncodedWordMatch(match: match, source: self, state: &state)
        }

        String.flushMIMEEncodedWordRun(&state.pendingRun, into: &state.result)
        let remainder = self[state.lastIndex...]
        state.result += String(remainder)
        return state.result
    }

    /// Append the decoded contents of the pending run (if any) to the result and
    /// clear the run. Used when the next encoded word breaks the current chain.
    fileprivate static func flushMIMEEncodedWordRun(
        _ pendingRun: inout MIMEEncodedWordRun?,
        into result: inout String
    ) {
        guard let currentRun = pendingRun else {
            return
        }
        if let decoded = decodeMIMEHeaderBytes(
            currentRun.bytes,
            preferredEncoding: currentRun.stringEncoding,
            transferEncoding: currentRun.encoding
        ) {
            result += decoded
        } else {
            result += currentRun.originalText
        }
        pendingRun = nil
    }

    /// Mutable state threaded through `decodeMIMEHeader`'s helpers so callers
    /// can stay well below SwiftLint's function parameter count limit.
    fileprivate struct MIMEHeaderDecodeState {
        var lastIndex: String.Index
        var hasPreviousEncodedWord: Bool
        var pendingRun: MIMEEncodedWordRun?
        var result: String
    }

    /// Parsed pieces of a single MIME encoded-word regex match.
    fileprivate struct MIMEEncodedWordParts {
        let normalizedCharset: String
        let encoding: String
        let stringEncoding: String.Encoding
        let encodedText: String
        let originalWord: String
        let upperBound: String.Index
        let between: Substring
    }

    /// Handle a single regex match within `decodeMIMEHeader`. Mutates the running
    /// state so the caller can keep its body small enough for SwiftLint.
    fileprivate static func processMIMEEncodedWordMatch(
        match: NSTextCheckingResult,
        source: String,
        state: inout MIMEHeaderDecodeState
    ) {
        guard let parts = parseMIMEEncodedWordParts(match: match, source: source, state: state) else {
            return
        }

        let isAdjacentEncodedWordWhitespace = state.hasPreviousEncodedWord &&
            parts.between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !parts.between.isEmpty && !isAdjacentEncodedWordWhitespace {
            flushMIMEEncodedWordRun(&state.pendingRun, into: &state.result)
            state.pendingRun = nil
            state.result += String(parts.between)
        }

        if let rawBytes = decodeMIMEEncodedWordBytes(parts.encodedText, encoding: parts.encoding) {
            mergeOrStartMIMEEncodedWordRun(
                rawBytes: rawBytes,
                parts: parts,
                isAdjacentEncodedWordWhitespace: isAdjacentEncodedWordWhitespace,
                state: &state
            )
        } else {
            flushMIMEEncodedWordRun(&state.pendingRun, into: &state.result)
            state.pendingRun = nil
            state.result += parts.originalWord
        }

        state.lastIndex = parts.upperBound
        state.hasPreviousEncodedWord = true
    }

    /// Extract and normalise the relevant substrings out of a regex match,
    /// returning `nil` when any required capture is missing.
    fileprivate static func parseMIMEEncodedWordParts(
        match: NSTextCheckingResult,
        source: String,
        state: MIMEHeaderDecodeState
    ) -> MIMEEncodedWordParts? {
        guard let range = Range(match.range, in: source),
              let charsetRange = Range(match.range(at: 1), in: source),
              let encodingRange = Range(match.range(at: 2), in: source),
              let textRange = Range(match.range(at: 3), in: source) else {
            return nil
        }

        let charset = String(source[charsetRange])
        return MIMEEncodedWordParts(
            normalizedCharset: charset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            encoding: String(source[encodingRange]).uppercased(),
            stringEncoding: String.Encoding(ianaCharsetName: charset) ?? .utf8,
            encodedText: String(source[textRange]),
            originalWord: String(source[range]),
            upperBound: range.upperBound,
            between: source[state.lastIndex..<range.lowerBound]
        )
    }

    /// Either append the freshly-decoded bytes to the in-flight run (when it
    /// shares charset and transfer encoding) or flush the previous run and
    /// start a new one.
    fileprivate static func mergeOrStartMIMEEncodedWordRun(
        rawBytes: Data,
        parts: MIMEEncodedWordParts,
        isAdjacentEncodedWordWhitespace: Bool,
        state: inout MIMEHeaderDecodeState
    ) {
        if var existingRun = state.pendingRun,
           isAdjacentEncodedWordWhitespace,
           existingRun.charset == parts.normalizedCharset,
           existingRun.encoding == parts.encoding {
            existingRun.bytes.append(rawBytes)
            existingRun.originalText += parts.originalWord
            state.pendingRun = existingRun
        } else {
            flushMIMEEncodedWordRun(&state.pendingRun, into: &state.result)
            state.pendingRun = MIMEEncodedWordRun(
                charset: parts.normalizedCharset,
                encoding: parts.encoding,
                stringEncoding: parts.stringEncoding,
                bytes: rawBytes,
                originalText: parts.originalWord
            )
        }
    }

    /// Detects the charset from content and returns the appropriate String.Encoding
    /// - Returns: The detected String.Encoding, or .utf8 as fallback
    public func detectCharsetEncoding() -> String.Encoding {
        // Look for Content-Type header with charset
        let contentTypePattern = "Content-Type:.*?charset=([^\\s;\"']+)"
        if let range = self.range(of: contentTypePattern, options: .regularExpression, range: nil, locale: nil),
           let charsetRange = self[range].range(of: "charset=([^\\s;\"']+)", options: .regularExpression) {
            let charsetString = self[charsetRange].replacingOccurrences(of: "charset=", with: "")
            return String.Encoding(ianaCharsetName: charsetString) ?? .utf8
        }

        // Look for meta tag with charset
        let metaPattern = "<meta[^>]*charset=([^\\s;\"'/>]+)"
        if let range = self.range(of: metaPattern, options: .regularExpression, range: nil, locale: nil),
           let charsetRange = self[range].range(of: "charset=([^\\s;\"'/>]+)", options: .regularExpression) {
            let charsetString = self[charsetRange].replacingOccurrences(of: "charset=", with: "")
            return String.Encoding(ianaCharsetName: charsetString) ?? .utf8
        }

        // Default to UTF-8
        return .utf8
    }

    /// Decode quoted-printable content in message bodies
    /// - Returns: The decoded content
    public func decodeQuotedPrintableContent() -> String {
        // Split the content into lines
        let lines = self.components(separatedBy: .newlines)
        var inBody = false
        var bodyContent = ""
        var headerContent = ""
        var contentEncoding: String.Encoding = .utf8

        // Process each line
        for line in lines {
            if !inBody {
                // Check if we've reached the end of headers
                if line.isEmpty {
                    inBody = true
                    headerContent += line + "\n"
                    continue
                }

                // Add header line
                headerContent += line + "\n"

                // Check for Content-Type header with charset
                if line.lowercased().contains("content-type:") && line.lowercased().contains("charset=") {
                    if let range = line.range(of: "charset=([^\\s;\"']+)", options: .regularExpression) {
                        let charsetString = line[range].replacingOccurrences(of: "charset=", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\"", with: "")
                            .replacingOccurrences(of: "'", with: "")
                        contentEncoding = String.Encoding(ianaCharsetName: charsetString) ?? .utf8
                    }
                }

                // Check if this is a Content-Transfer-Encoding header
                if line.lowercased().contains("content-transfer-encoding:") &&
                    line.lowercased().contains("quoted-printable") {
                    // Found quoted-printable encoding
                    inBody = false
                }
            } else {
                // Add body line
                bodyContent += line + "\n"
            }
        }

        // If we found quoted-printable encoding, decode the body
        if !bodyContent.isEmpty {
            // Decode the body content with the detected encoding
            if let decodedBody = bodyContent.decodeQuotedPrintable(encoding: contentEncoding) {
                return headerContent + decodedBody
            } else if let decodedBody = bodyContent.decodeQuotedPrintable() {
                // Fallback to UTF-8 if the specified charset fails
                return headerContent + decodedBody
            }
        }

        // If we didn't find quoted-printable encoding or no body content,
        // try to decode the entire content with the detected charset
        if let decodedContent = self.decodeQuotedPrintable(encoding: contentEncoding) {
            return decodedContent
        }

        // Last resort: try with UTF-8
        return self.decodeQuotedPrintable() ?? self
    }

    fileprivate static func decodeMIMEEncodedWordBytes(_ encodedText: String, encoding: String) -> Data? {
        switch encoding {
            case "B":
                return Data(base64Encoded: encodedText, options: .ignoreUnknownCharacters)
            case "Q":
                return decodeMIMEHeaderQuotedPrintableBytes(
                    encodedText.replacingOccurrences(of: "_", with: " ")
                )
            default:
                return nil
        }
    }

    fileprivate static func decodeMIMEHeaderBytes(
        _ bytes: Data,
        preferredEncoding: String.Encoding,
        transferEncoding: String
    ) -> String? {
        if let decoded = String(data: bytes, encoding: preferredEncoding) {
            return decoded
        }

        if preferredEncoding != .utf8, let decoded = String(data: bytes, encoding: .utf8) {
            return decoded
        }

        if transferEncoding == "Q", preferredEncoding != .isoLatin1,
           let decoded = String(data: bytes, encoding: .isoLatin1) {
            return decoded
        }

        return nil
    }

    fileprivate static func decodeMIMEHeaderQuotedPrintableBytes(_ text: String) -> Data? {
        let withoutSoftBreaks = text.replacingOccurrences(of: "=\r\n", with: "")
            .replacingOccurrences(of: "=\n", with: "")

        var bytes = Data()
        var index = withoutSoftBreaks.startIndex

        while index < withoutSoftBreaks.endIndex {
            let character = withoutSoftBreaks[index]

            if character == "=" {
                let nextIndex = withoutSoftBreaks.index(after: index)
                guard nextIndex < withoutSoftBreaks.endIndex else {
                    return nil
                }

                let nextNextIndex = withoutSoftBreaks.index(after: nextIndex)
                guard nextNextIndex < withoutSoftBreaks.endIndex else {
                    return nil
                }

                let hex = String(withoutSoftBreaks[nextIndex...nextNextIndex])
                guard let byte = UInt8(hex, radix: 16) else {
                    return nil
                }

                bytes.append(byte)
                index = withoutSoftBreaks.index(after: nextNextIndex)
                continue
            }

            if let ascii = character.asciiValue {
                bytes.append(ascii)
            } else if let data = String(character).data(using: .utf8) {
                bytes.append(contentsOf: data)
            }

            index = withoutSoftBreaks.index(after: index)
        }

        return bytes
    }
}
