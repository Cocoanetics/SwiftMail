// AddressSyntax.swift
// Character classes and canonical forms of RFC 5322 address syntax.

import Foundation

/// The character classes of RFC 5322 §3.2 address syntax, extended to UTF-8 by
/// RFC 6532, and the canonical forms the address parser produces.
enum AddressSyntax {
    /// The `specials` of RFC 5322 §3.2.3: the ASCII characters that delimit atoms.
    private static let specials: Set<Unicode.Scalar> = [
        "(", ")", "<", ">", "[", "]", ":", ";", "@", "\\", ",", ".", "\""
    ]

    /// WSP: space and horizontal tab, and nothing else. Other Unicode spaces,
    /// such as U+00A0, are text (RFC 6532).
    static func isWSP(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t"
    }

    /// A control character that address syntax never carries literally: a C0
    /// control other than HTAB, DEL, or a C1 control. CR and LF may only appear
    /// as the line break of folding white space, and some software treats other
    /// controls, such as VT, FF or NEL, as line breaks too.
    static func isForbiddenControl(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value < 0x20 && scalar != "\t") || (0x7F...0x9F).contains(scalar.value)
    }

    /// A control character that a recovered display name may carry as text:
    /// any forbidden control other than CR and LF, such as a C1 control that a
    /// Windows-1252 byte becomes when a header is read as Latin-1. The
    /// formatter encodes such a name, so it never reaches a header raw.
    static func isControlInText(_ scalar: Unicode.Scalar) -> Bool {
        isForbiddenControl(scalar) && scalar != "\r" && scalar != "\n"
    }

    /// VCHAR, which RFC 6532 extends to every non-ASCII scalar. C1 controls are
    /// left out: they are controls, not text.
    static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        (0x21...0x7E).contains(scalar.value) || scalar.value >= 0xA0
    }

    /// atext: visible characters other than `specials`.
    static func isAtext(_ scalar: Unicode.Scalar) -> Bool {
        isVisible(scalar) && !specials.contains(scalar)
    }

    /// qtext or WSP: what a quoted-string holds between quoted-pairs.
    static func isQuotedText(_ scalar: Unicode.Scalar) -> Bool {
        isWSP(scalar) || (isVisible(scalar) && scalar != "\"" && scalar != "\\")
    }

    /// ctext or WSP: what a comment holds besides quoted-pairs and nested comments.
    static func isCommentText(_ scalar: Unicode.Scalar) -> Bool {
        isWSP(scalar) || (isVisible(scalar) && scalar != "(" && scalar != ")" && scalar != "\\")
    }

    /// dtext or WSP: what a domain literal holds between its brackets.
    static func isDomainText(_ scalar: Unicode.Scalar) -> Bool {
        isWSP(scalar) || (isVisible(scalar) && scalar != "[" && scalar != "]" && scalar != "\\")
    }

    /// An addr-spec in canonical form. The local-part is a dot-atom when it can
    /// be one and a quoted-string otherwise, so `"john"@example.com` and
    /// `john@example.com` both come out as `john@example.com`.
    ///
    /// - Parameters:
    ///   - localPart: The local-part's text, without quoting.
    ///   - domain: The domain, a dot-atom or a domain literal.
    static func addrSpec(localPart: String, domain: String) -> String {
        let local = isDotAtomText(localPart) ? localPart : quotedString(localPart)
        return local + "@" + domain
    }

    /// The addr-spec of an IMAP ENVELOPE address, whose mailbox is the
    /// local-part's text: servers such as Dovecot hand it over without the
    /// quotes it needs, as `john doe` for `"john doe"@example.com`, so it is
    /// quoted where a dot-atom can't carry it. A mailbox that already is a
    /// quoted-string is kept as it is.
    static func envelopeAddrSpec(mailbox: String, host: String) -> String {
        var probe = AddressScanner(mailbox)
        if mailbox.hasPrefix("\""), (try? probe.readQuotedString()) != nil, probe.isAtEnd {
            return mailbox + "@" + host
        }
        return addrSpec(localPart: mailbox, domain: host)
    }

    /// Whether `text` is a dot-atom-text: atext runs joined by single dots.
    static func isDotAtomText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { run in
            !run.isEmpty && run.allSatisfy(isAtext)
        }
    }

    /// `text` as a quoted-string, with `"` and `\` escaped as quoted-pairs.
    static func quotedString(_ text: String) -> String {
        var quoted = String.UnicodeScalarView()
        quoted.append("\"")
        for scalar in text.unicodeScalars {
            if scalar == "\"" || scalar == "\\" {
                quoted.append("\\")
            }
            quoted.append(scalar)
        }
        quoted.append("\"")
        return String(quoted)
    }
}

extension String {
    /// A string made of the given Unicode scalars.
    init<Scalars: Sequence>(unicodeScalars scalars: Scalars) where Scalars.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        self.init(view)
    }
}
