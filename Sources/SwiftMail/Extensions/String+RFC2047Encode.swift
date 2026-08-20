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

    /// Whether `scalar` is one that a header field body cannot carry literally.
    ///
    /// RFC 5322 §2.2 limits a field body to printable US-ASCII (0x21–0x7E) plus
    /// SP and HTAB, so everything below SP and everything from DEL upwards —
    /// the C0 controls, DEL, the C1 range, and all non-ASCII text — needs an
    /// encoded-word. CR and LF are the dangerous members: they *end the field*,
    /// so a value carrying them silently becomes additional header lines when it
    /// is interpolated into one.
    ///
    /// Membership is decided on the Unicode SCALAR, never on `Character`. A
    /// `Character` is an extended grapheme cluster and CR-LF is a single one, so
    /// `Character.isASCII` answers `true` for a whole `\r\n` pair and a
    /// `Character`-based test cannot see it.
    ///
    /// HTAB is excluded deliberately: it is WSP, which RFC 5322 §3.2.5 allows
    /// literally in an unstructured field body, so encoding it would change the
    /// output of ordinary values for no benefit.
    private static func rfc2047RequiresEncoding(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0x09 { return false } // HTAB is legal WSP
        return scalar.value < 0x20 || scalar.value >= 0x7F
    }

    /// Encode the receiver as one or more RFC 2047 Base64 encoded-words when it
    /// contains anything a header field body cannot carry literally — non-ASCII
    /// text, a C0 control, DEL, or a C1 control. A value made only of printable
    /// US-ASCII, SP and HTAB is already a valid header value and is returned
    /// unchanged.
    ///
    /// Encoding rather than rejecting keeps the library non-throwing and loses
    /// nothing: an encoded-word is the standard carrier for octets a header
    /// cannot hold literally, so the recipient still sees exactly what the
    /// caller wrote.
    ///
    /// Multiple encoded-words are folded with `CRLF SPACE` so each stays within
    /// the 75-octet limit; a character's UTF-8 bytes are never split across two
    /// encoded-words, so every word decodes independently (required by clients
    /// that decode each word in isolation). Round-trips through
    /// ``decodeMIMEHeader()``.
    public func rfc2047EncodedHeader() -> String {
        guard self.unicodeScalars.contains(where: Self.rfc2047RequiresEncoding) else { return self }
        return rfc2047EncodedWords()
    }

    /// Encode the receiver as RFC 2047 encoded-word(s) unconditionally.
    ///
    /// Used by callers that apply their own trigger — a display name also has to
    /// be encoded when it carries the `"` or `\` that would otherwise escape the
    /// quoted-string around it, although both are ordinary text elsewhere.
    func rfc2047EncodedWords() -> String {
        var words: [String] = []
        var chunk: [UInt8] = []

        func flush() {
            guard !chunk.isEmpty else { return }
            words.append("=?UTF-8?B?\(Data(chunk).base64EncodedString())?=")
            chunk.removeAll(keepingCapacity: true)
        }

        func append(_ bytes: [UInt8]) {
            if !chunk.isEmpty, chunk.count + bytes.count > Self.rfc2047MaxBytesPerWord {
                flush()
            }
            chunk.append(contentsOf: bytes)
        }

        // Split between `Character`s — extended grapheme clusters — so a word
        // boundary never lands in the middle of one. That is the right unit
        // whenever a cluster can fit in a word at all, and it is what keeps the
        // output of ordinary text byte-identical to the pre-existing behaviour.
        //
        // The one case it cannot handle is a cluster wider than
        // `rfc2047MaxBytesPerWord` on its own: there is no boundary inside it to
        // flush at, so it lands alone in an oversized word. "a" followed by 23
        // combining marks is 47 UTF-8 bytes, giving a 12 + 4*ceil(47/3) =
        // 76-octet word, over RFC 2047 §2's ceiling. Only there do we descend to
        // Unicode scalars: a scalar is at most 4 bytes, so the chunks built from
        // one never exceed 45 bytes and the widest word is
        // 12 + 4*ceil(45/3) = 72 octets. Splitting between scalars still leaves
        // every word independently valid UTF-8, which is the property the
        // `!chunk.isEmpty` guard exists to protect; only the grapheme cluster
        // itself is divided, and only because it cannot be carried whole.
        for character in self {
            let bytes = Array(String(character).utf8)
            if bytes.count <= Self.rfc2047MaxBytesPerWord {
                append(bytes)
                continue
            }
            flush()
            for scalar in character.unicodeScalars {
                append(Array(String(scalar).utf8))
            }
        }
        flush()

        // CRLF+SPACE between adjacent encoded-words: the linear whitespace is
        // dropped on decode (RFC 2047 §2), reassembling the original text.
        return words.joined(separator: "\r\n ")
    }

    /// Whether the receiver has to be RFC 2047-encoded to appear as the display
    /// name of an address, i.e. it is not a valid field body literally *or* it
    /// carries a character that would escape the surrounding quoted-string.
    var rfc2047RequiresEncodingAsDisplayName: Bool {
        unicodeScalars.contains { scalar in
            Self.rfc2047RequiresEncoding(scalar) || scalar == "\"" || scalar == "\\"
        }
    }
}
