// String+RFC2047Encode.swift
// RFC 2047 "encoded-word" ENCODING for non-ASCII header values (the inverse of
// `decodeMIMEHeader()` in String+QuotedPrintable+MIMEHeader.swift).
//
// RFC 5322 requires header field bodies to be 7-bit ASCII. Any non-ASCII text
// (e.g. a Korean Subject or display name) MUST be wrapped in an RFC 2047
// encoded-word; emitting raw 8-bit bytes in a header invites downstream agents
// to apply their own charset guesses and produce mojibake. (Message *bodies*
// are unaffected because they carry an explicit charset + transfer-encoding;
// header fields have no such mechanism other than RFC 2047.)

import Foundation

extension String {
    /// Max UTF-8 bytes encoded per encoded-word. `=?UTF-8?B?` (10) + `?=` (2)
    /// is 12 octets of overhead and Base64 of N bytes is `4*ceil(N/3)`; 45 bytes
    /// → 60 Base64 chars → a 72-octet word, safely under RFC 2047 §2's 75-octet
    /// per-encoded-word ceiling.
    private static let rfc2047MaxBytesPerWord = 45

    /// Encode the receiver as one or more RFC 2047 Base64 encoded-words when it
    /// contains any non-ASCII character. Pure-ASCII input is returned unchanged
    /// (it is already a valid header value).
    ///
    /// Multiple encoded-words are folded with `CRLF SPACE` so each stays within
    /// the 75-octet limit; a character's UTF-8 bytes are never split across two
    /// encoded-words, so every word decodes independently (required by clients
    /// that decode each word in isolation). Round-trips through
    /// ``decodeMIMEHeader()``.
    public func rfc2047EncodedHeader() -> String {
        guard self.contains(where: { !$0.isASCII }) else { return self }

        var words: [String] = []
        var chunk: [UInt8] = []

        func flush() {
            guard !chunk.isEmpty else { return }
            words.append("=?UTF-8?B?\(Data(chunk).base64EncodedString())?=")
            chunk.removeAll(keepingCapacity: true)
        }

        for character in self {
            let bytes = Array(String(character).utf8)
            if !chunk.isEmpty, chunk.count + bytes.count > Self.rfc2047MaxBytesPerWord {
                flush()
            }
            chunk.append(contentsOf: bytes)
        }
        flush()

        // CRLF+SPACE between adjacent encoded-words: the linear whitespace is
        // dropped on decode (RFC 2047 §2), reassembling the original text.
        return words.joined(separator: "\r\n ")
    }
}
