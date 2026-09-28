// AddressFormatter.swift
// The one formatter from structured addresses to RFC 5322 text.

import Foundation

/// Writes structured addresses as RFC 5322 text that ``AddressParser`` reads
/// back to the identical value.
///
/// Two forms share the same syntax:
///
/// - The **header** form is what a header field carries, and what
///   ``EmailAddress/description`` returns. A display name that isn't printable
///   ASCII, or that holds a `"` or `\`, is written as RFC 2047 encoded-words.
/// - The **display** form keeps names readable: UTF-8 text stays as it is
///   (RFC 6532), and `"` and `\` are escaped inside a quoted-string. Only a
///   name holding a control character is encoded, as nothing else can carry it.
///
/// In both forms a name is quoted unless it is plain words separated by single
/// spaces, so white space, punctuation and encoded-word look-alikes survive: a
/// quoted-string is always literal. Neither form writes a control character,
/// apart from the CRLF that folds a long encoded name, so an address can never
/// start a header field of its own.
enum AddressFormatter {
    enum Form {
        case header
        case display
    }

    /// The text of a mailbox: `name <address>`, or the bare address without a name.
    static func string(for address: EmailAddress, form: Form) -> String {
        let addrSpec = withoutControls(address.address, replacement: nil)
        guard let name = address.name, !name.isEmpty else { return addrSpec }
        return phrase(name, form: form) + " <" + addrSpec + ">"
    }

    /// The text of an address-list element. A group is `name: members;`, and
    /// invalid text is written as it is, with any control character replaced by
    /// a space.
    static func string(for entry: AddressListEntry, form: Form) -> String {
        switch entry {
            case .mailbox(let address):
                return string(for: address, form: form)
            case let .group(name, members):
                let list = members.map { string(for: $0, form: form) }.joined(separator: ", ")
                return phrase(name, form: form) + ":" + (list.isEmpty ? "" : " " + list) + ";"
            case .invalid(let text):
                return withoutControls(text, replacement: " ")
        }
    }

    /// A display name the way address strings built from an IMAP ENVELOPE
    /// have always carried it: quoted, with `"` and `\` escaped so the string
    /// reads back as the same name. A name holding a control character is
    /// encoded instead, as no quoted-string can carry one.
    static func quotedPhrase(_ name: String) -> String {
        if name.unicodeScalars.contains(where: AddressSyntax.isForbiddenControl) {
            return name.rfc2047EncodedWords()
        }
        return AddressSyntax.quotedString(name)
    }

    /// A group written from its name and the text of its members:
    /// `name: member, member;`, or `name:;` without members.
    static func groupString(name: String, members: [String]) -> String {
        let list = members.joined(separator: ", ")
        return phrase(name, form: .display) + ":" + (list.isEmpty ? "" : " " + list) + ";"
    }

    /// A display name or group name as a phrase.
    static func phrase(_ name: String, form: Form) -> String {
        let needsEncoding: Bool
        switch form {
            case .header:
                needsEncoding = name.rfc2047RequiresEncodingAsDisplayName
            case .display:
                needsEncoding = name.unicodeScalars.contains(where: AddressSyntax.isForbiddenControl)
        }
        if needsEncoding {
            return name.rfc2047EncodedWords()
        }
        return isPlainPhrase(name, allowsNonASCII: form == .display) ? name : AddressSyntax.quotedString(name)
    }

    /// Whether `name` is words separated by single spaces, each made of
    /// letters, digits, `-`, `'` and `_`. A phrase carries such a name
    /// unquoted and reads it back unchanged: those are all atext, and a word
    /// of them can never be taken for an encoded-word.
    private static func isPlainPhrase(_ name: String, allowsNonASCII: Bool) -> Bool {
        guard !name.isEmpty else { return false }
        let words = name.unicodeScalars.split(separator: " ", omittingEmptySubsequences: false)
        return words.allSatisfy { word in
            !word.isEmpty && word.allSatisfy { isPlainWordScalar($0, allowsNonASCII: allowsNonASCII) }
        }
    }

    private static func isPlainWordScalar(_ scalar: Unicode.Scalar, allowsNonASCII: Bool) -> Bool {
        guard scalar.isASCII else {
            let properties = scalar.properties
            return allowsNonASCII && AddressSyntax.isAtext(scalar)
                && (properties.isAlphabetic || properties.numericType != nil)
        }
        return ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
            || scalar == "-" || scalar == "'" || scalar == "_"
    }

    /// `text` without the control characters a header field can't hold (see
    /// ``AddressSyntax/isForbiddenControl(_:)``): dropped, or replaced by
    /// `replacement`. HTAB is kept, as a quoted local-part may hold it.
    private static func withoutControls(_ text: String, replacement: Unicode.Scalar?) -> String {
        guard text.unicodeScalars.contains(where: AddressSyntax.isForbiddenControl) else { return text }
        var safe = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if !AddressSyntax.isForbiddenControl(scalar) {
                safe.append(scalar)
            } else if let replacement {
                safe.append(replacement)
            }
        }
        return String(safe)
    }
}
