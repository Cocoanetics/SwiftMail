// String+QuotedPrintable+Encoding.swift
// Quoted-Printable encoding logic split off from the main file to keep
// function bodies and file length within SwiftLint's structural limits.

import Foundation

extension String {
    /// Encodes the string using quoted-printable encoding
    public func quotedPrintableEncoded() -> String {
        let normalizedLineEndings = replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let logicalLines = normalizedLineEndings.split(separator: "\n", omittingEmptySubsequences: false)
        return logicalLines.map(String.encodeQuotedPrintableLogicalLine).joined(separator: "\r\n")
    }

    /// Token produced by quoted-printable encoding of a single source byte.
    fileprivate struct QPToken {
        let value: String
        let isLiteralWhitespace: Bool
    }

    /// Quoted-printable line limits.
    fileprivate static let qpMaxLineLength = 76
    fileprivate static var qpMaxContentLengthForSoftBreak: Int {
        qpMaxLineLength - 1
    }

    /// Encode a single source byte into a quoted-printable token, honouring the
    /// special end-of-line rules for SP/TAB characters.
    fileprivate static func qpToken(for byte: UInt8, isEndOfLogicalLine: Bool) -> QPToken {
        switch byte {
            case UInt8(ascii: "="):
                return QPToken(value: "=3D", isLiteralWhitespace: false)
            case UInt8(ascii: " "):
                if isEndOfLogicalLine {
                    return QPToken(value: "=20", isLiteralWhitespace: false)
                }
                return QPToken(value: " ", isLiteralWhitespace: true)
            case UInt8(ascii: "\t"):
                if isEndOfLogicalLine {
                    return QPToken(value: "=09", isLiteralWhitespace: false)
                }
                return QPToken(value: "\t", isLiteralWhitespace: true)
            case 33 ... 60, 62 ... 126:
                return QPToken(value: String(UnicodeScalar(byte)), isLiteralWhitespace: false)
            default:
                return QPToken(value: String(format: "=%02X", byte), isLiteralWhitespace: false)
        }
    }

    /// Encode a single logical line (already split on newline) by tokenising it
    /// and wrapping the output with soft line breaks where needed.
    fileprivate static func encodeQuotedPrintableLogicalLine(_ line: Substring) -> String {
        let bytes = Array(line.utf8)
        var encodedTokens: [QPToken] = []
        encodedTokens.reserveCapacity(bytes.count)
        for (index, byte) in bytes.enumerated() {
            encodedTokens.append(qpToken(for: byte, isEndOfLogicalLine: index == bytes.count - 1))
        }
        return wrapQuotedPrintableTokens(encodedTokens)
    }

    /// Wraps the encoded tokens with soft line breaks honouring the 76-character
    /// limit (minus one for the trailing `=` marker on continuation lines).
    fileprivate static func wrapQuotedPrintableTokens(_ encodedTokens: [QPToken]) -> String {
        var wrappedLines: [String] = []
        var currentTokens: [QPToken] = []
        var currentLength = 0
        for token in encodedTokens {
            if currentLength + token.value.count > qpMaxContentLengthForSoftBreak {
                flushQuotedPrintableLineWithSoftBreak(
                    currentTokens: &currentTokens,
                    currentLength: &currentLength,
                    wrappedLines: &wrappedLines
                )
            }
            currentTokens.append(token)
            currentLength += token.value.count
        }
        wrappedLines.append(currentTokens.map(\.value).joined())
        return wrappedLines.joined(separator: "\r\n")
    }

    /// Emit the current run of tokens as a soft-wrapped line, escaping any
    /// trailing literal whitespace so it survives the line break.
    fileprivate static func flushQuotedPrintableLineWithSoftBreak(
        currentTokens: inout [QPToken],
        currentLength: inout Int,
        wrappedLines: inout [String]
    ) {
        guard !currentTokens.isEmpty else {
            return
        }
        var carriedTokens: [QPToken] = []
        while let last = currentTokens.last, last.isLiteralWhitespace {
            _ = currentTokens.popLast()
            currentLength -= last.value.count
            let encodedWhitespace = QPToken(
                value: last.value == " " ? "=20" : "=09",
                isLiteralWhitespace: false
            )
            if currentLength + encodedWhitespace.value.count <= qpMaxContentLengthForSoftBreak {
                currentTokens.append(encodedWhitespace)
                currentLength += encodedWhitespace.value.count
            } else {
                carriedTokens.insert(encodedWhitespace, at: 0)
            }
        }
        wrappedLines.append(currentTokens.map(\.value).joined() + "=")
        currentTokens = carriedTokens
        currentLength = carriedTokens.reduce(0) { $0 + $1.value.count }
    }
}
