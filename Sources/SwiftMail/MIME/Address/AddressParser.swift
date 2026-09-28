// AddressParser.swift
// The one parser that turns RFC 5322 address text into structured addresses.

import Foundation

/// Parses RFC 5322 address fields, such as `From`, `To`, `Cc`, `Bcc` and
/// `Reply-To`, into structured addresses.
///
/// This is the only place SwiftMail reads address syntax. It covers the whole
/// address grammar of RFC 5322 §3.4, including the obsolete forms of §4.4 that
/// real mail still carries (source routes, CFWS around dots, empty list
/// elements, and `.` in display names), UTF-8 wherever RFC 6532 allows it, and
/// RFC 2047 encoded-words in display names.
///
/// - Comments and folding white space are syntax, never part of an address.
///   The one exception is the legacy form `user@example.com (Name)` that
///   RFC 5322 §3.4 describes: the first trailing comment of an address without
///   angle brackets becomes its display name.
/// - Addresses come back in canonical form: without CFWS or a source route, and
///   with a quoted local-part only where a dot-atom can't carry it, so
///   `"john"@example.com` becomes `john@example.com`.
/// - An encoded-word is decoded only where RFC 2047 §5 allows it: as a whole
///   word of a display name, set off from the words around it by white space
///   or a comment. Inside a quoted-string it is literal text.
/// - An address is never guessed at, repaired or dropped. A few malformations
///   common in real mail are read anyway, because the address they name is
///   unambiguous: a display name that breaks the phrase grammar in front of a
///   well-formed `<address>` (`John [Sales] <john@example.com>`), a group
///   missing its final ";", and a local-part with a leading, trailing or
///   doubled dot (`taro.@docomo.ne.jp`). Any other element that doesn't match
///   the grammar, such as a missing comma, a control character in an address,
///   or an unterminated quoted-string, comment, domain literal or angle
///   bracket, becomes an ``AddressListEntry/invalid(_:)`` entry that keeps its
///   text. That text reaches up to the next comma the malformed syntax doesn't
///   swallow, and the elements around it are read normally.
/// - An element that is nothing but a quoted-string, or nothing but
///   encoded-words, is invalid text of the text it stands for. That is how
///   SwiftMail writes invalid text that would otherwise read back as something
///   else: encoded-words in a header, and `"Doe, John"` for display.
///
/// ``AddressListEntry/description`` and ``EmailAddress/description`` write the
/// text this parser reads back to the identical value.
public enum AddressParser {
    /// Parses an address field body into its elements.
    ///
    /// Parsing never fails: malformed text comes back as
    /// ``AddressListEntry/invalid(_:)`` entries, and empty elements (`a, , b`)
    /// are skipped.
    ///
    /// Elements are never merged: in `Doe, John <john@example.com>` the comma
    /// separates invalid text, `Doe`, from the mailbox `John`. (Text known to be
    /// one mailbox, such as ``EmailAddress/init(_:)`` reads, may hold an
    /// unquoted comma in its display name.)
    ///
    /// - Parameter text: A field body, such as the value of a `To:` header field.
    ///   Folded lines are unfolded.
    /// - Returns: The mailboxes, groups and invalid text of the field, in order.
    public static func parseAddressList(_ text: String) -> [AddressListEntry] {
        var scanner = AddressScanner(text)
        var entries: [AddressListEntry] = []
        while let entry = scanner.readListElement() {
            entries.append(entry)
        }
        return entries
    }

    /// Parses text that is exactly one mailbox, or returns `nil`. As the text
    /// can't be a list, a display name may also hold an unquoted comma, as in
    /// `Doe, Jane <jane@example.com>` (see
    /// ``AddressScanner/recoverNameAddr(in:allowsCommas:)``).
    static func parseMailbox(_ text: String) -> EmailAddress? {
        var scanner = AddressScanner(text)
        if let mailbox = try? scanner.readMailbox(), scanner.isAtEnd {
            return mailbox
        }
        return scanner.recoverNameAddr(in: 0..<scanner.scalars.count, allowsCommas: true)
    }
}
