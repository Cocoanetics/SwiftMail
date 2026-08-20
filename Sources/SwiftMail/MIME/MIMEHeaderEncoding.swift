// MIMEHeaderEncoding.swift
// Serialization of MIME header parameters and of the field bodies that carry
// them. Used by every place the library writes a part header, so that a value
// which cannot be written literally has exactly one treatment.

import Foundation

/// Writes MIME header parameters and header field bodies.
///
/// Values such as an attachment filename or a content type arrive from callers
/// and, on the receive side, from remote senders. Interpolating them straight
/// into a header line lets an embedded `"` close the quoted-string and start
/// another parameter, and lets a CR or LF end the field and open a new one.
enum MIMEHeaderEncoding {

    /// Emit `name=value` for a MIME header parameter.
    ///
    /// A value that can be written literally inside a quoted-string is emitted
    /// as `name="value"`, byte for byte as before. Anything else — an embedded
    /// `"` or `\`, a control character, or non-ASCII text — is emitted as a
    /// single RFC 2231 §4 extended parameter, `name*=UTF-8''<percent-encoded>`.
    ///
    /// Exactly one of the two forms is emitted, selected by the value; the two
    /// are never emitted side by side, so a receiver has nothing to choose
    /// between. The extended form is deliberately a single segment: RFC 2231 §3
    /// continuations (`name*0*=`, `name*1*=`) would be legal but are far less
    /// widely implemented, and the value has to survive one header line.
    static func parameter(name: String, value: String) -> String {
        guard value.unicodeScalars.allSatisfy(isSafeInQuotedString) else {
            return "\(name)*=UTF-8''\(percentEncoded(value))"
        }
        return "\(name)=\"\(value)\""
    }

    /// Make `value` safe to interpolate into a header field body.
    ///
    /// RFC 5322 §2.2 limits a field body to printable US-ASCII plus SP and HTAB,
    /// and a CR or LF *ends the field*, so anything after one is read as a new
    /// header. Values that carry their own parameter syntax — a content type
    /// such as `text/calendar; method=REQUEST`, a Content-ID — cannot be wrapped
    /// in an encoded-word or an extended parameter without destroying that
    /// syntax, so the scalars a field body cannot hold are removed instead.
    ///
    /// A value that is already a valid field body is returned unchanged, so this
    /// only ever alters a value that could not have been emitted correctly.
    static func fieldBody(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: isForbiddenInFieldBody) else { return value }
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars where !isForbiddenInFieldBody(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    // MARK: - Predicates

    /// Whether `scalar` can appear literally between the quotes of a MIME
    /// parameter's quoted-string: printable US-ASCII, minus the `"` that would
    /// close it and the `\` that would start a quoted-pair.
    ///
    /// Stricter than ``isForbiddenInFieldBody`` on one scalar, HTAB, and
    /// deliberately: a parameter value has somewhere else to go — HTAB survives
    /// exactly as `%09` in the extended form — whereas a field body that must
    /// keep its own parameter syntax has no encoded form to fall back to and so
    /// keeps HTAB literally, as the legal WSP it is. Rejecting it here also
    /// avoids emitting whitespace a receiver unfolding the header may collapse.
    private static func isSafeInQuotedString(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.value >= 0x20, scalar.value < 0x7F else { return false }
        return scalar != "\"" && scalar != "\\"
    }

    /// Whether `scalar` is one a header field body cannot carry literally: a C0
    /// control, DEL, a C1 control, or non-ASCII text. HTAB is excluded — it is
    /// WSP, which RFC 5322 §3.2.5 allows literally.
    ///
    /// Decided on the Unicode SCALAR, never on `Character`: CR-LF is a single
    /// extended grapheme cluster, so `Character.isASCII` answers `true` for a
    /// whole `\r\n` pair and cannot see it.
    private static func isForbiddenInFieldBody(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0x09 { return false } // HTAB is legal WSP
        return scalar.value < 0x20 || scalar.value >= 0x7F
    }

    // MARK: - RFC 2231 percent-encoding

    /// RFC 2231 §7 `attribute-char`: any US-ASCII character except SPACE, the
    /// controls, `*`, `'`, `%` and the RFC 2045 tspecials. Everything else is
    /// percent-encoded from its UTF-8 bytes.
    private static let attributeCharacters: Set<UInt8> = {
        var allowed = Set<UInt8>()
        allowed.formUnion(UInt8(ascii: "a")...UInt8(ascii: "z"))
        allowed.formUnion(UInt8(ascii: "A")...UInt8(ascii: "Z"))
        allowed.formUnion(UInt8(ascii: "0")...UInt8(ascii: "9"))
        allowed.formUnion("!#$&+-.^_`{|}~".utf8)
        return allowed
    }()

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    private static func percentEncoded(_ value: String) -> String {
        var encoded = ""
        for byte in value.utf8 {
            if attributeCharacters.contains(byte) {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                encoded.unicodeScalars.append("%")
                encoded.unicodeScalars.append(Unicode.Scalar(hexDigits[Int(byte >> 4)]))
                encoded.unicodeScalars.append(Unicode.Scalar(hexDigits[Int(byte & 0x0F)]))
            }
        }
        return encoded
    }
}
