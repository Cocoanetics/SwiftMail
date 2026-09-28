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

    /// The text of a mailbox: `name <address>`, or the bare address without a
    /// name. An address holding a control character can't be written in any
    /// form, and stripping the control would name a different mailbox, so such
    /// a mailbox is written as encoded-words instead: they never read back as
    /// an address, nor as a header field of their own.
    static func string(for address: EmailAddress, form: Form) -> String {
        guard !address.address.unicodeScalars.contains(where: AddressSyntax.isForbiddenControl) else {
            return invalidText(name: address.name, address: address.address).rfc2047EncodedWords()
        }
        guard let name = address.name, !name.isEmpty else { return address.address }
        return phrase(name, form: form) + " <" + address.address + ">"
    }

    /// The text of an address-list element. A group is `name: members;`.
    /// Invalid text is written as it is, keeping any address a lenient reader
    /// can still find in it, unless it holds a control character: then it is
    /// written as encoded-words, which a header can carry and which never read
    /// as an address (replacing the control could turn the text into one).
    static func string(for entry: AddressListEntry, form: Form) -> String {
        switch entry {
            case .mailbox(let address):
                return string(for: address, form: form)
            case let .group(name, members):
                let list = members.map { string(for: $0, form: form) }.joined(separator: ", ")
                return phrase(name, form: form) + ":" + (list.isEmpty ? "" : " " + list) + ";"
            case .invalid(let text):
                let hasControl = text.unicodeScalars.contains(where: AddressSyntax.isForbiddenControl)
                return hasControl ? text.rfc2047EncodedWords() : text
        }
    }

    /// Text for a name and address that don't make a mailbox, to keep as
    /// ``AddressListEntry/invalid(_:)``: the name as a phrase, and the address
    /// exactly as given. A control character in it is kept too, so the text is
    /// written as encoded-words; stripping it could leave a valid address that
    /// reads back as a mailbox the source never named.
    static func invalidText(name: String?, address: String) -> String {
        guard let name, !name.isEmpty else { return address }
        return phrase(name, form: .display) + " <" + address + ">"
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

}
