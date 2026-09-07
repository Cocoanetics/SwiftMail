// EMLParser+RFC2047.swift
// RFC 2047 encoded-word decoding for parsed EML headers.

extension EMLParser {

    // MARK: - RFC 2047 Encoded Word Decoding

    /// Decode RFC 2047 encoded words (=?charset?encoding?text?=).
    static func decodeRFC2047(_ input: String) -> String? {
        input.decodeMIMEHeader()
    }
}
