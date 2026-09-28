// MessageInfo+Addresses.swift
// The address fields of a MessageInfo as text, derived from their structured form.

import Foundation

public extension MessageInfo {
    /// The sender of the message as text: every entry of ``fromAddresses``, in
    /// readable RFC 5322 form, joined by ", ". `nil` when there is none.
    ///
    /// Derived from ``fromAddresses``, so the two never disagree. Setting it
    /// parses the text into ``fromAddresses``.
    var from: String? {
        get { fromAddresses.isEmpty ? nil : Self.text(of: fromAddresses).joined(separator: ", ") }
        set { fromAddresses = newValue.map(AddressParser.parseAddressList) ?? [] }
    }

    /// The addresses to which replies should be sent, as text: one string per
    /// entry of ``replyToAddresses``. Setting it parses each string.
    var replyTo: [String] {
        get { Self.text(of: replyToAddresses) }
        set { replyToAddresses = Self.entries(parsing: newValue) }
    }

    /// The recipients of the message, as text: one string per entry of
    /// ``toAddresses``, so a group is one string. Setting it parses each string.
    var to: [String] {
        get { Self.text(of: toAddresses) }
        set { toAddresses = Self.entries(parsing: newValue) }
    }

    /// The CC recipients of the message, as text: one string per entry of
    /// ``ccAddresses``. Setting it parses each string.
    var cc: [String] {
        get { Self.text(of: ccAddresses) }
        set { ccAddresses = Self.entries(parsing: newValue) }
    }

    /// The BCC recipients of the message, as text: one string per entry of
    /// ``bccAddresses``. Setting it parses each string.
    var bcc: [String] {
        get { Self.text(of: bccAddresses) }
        set { bccAddresses = Self.entries(parsing: newValue) }
    }

    /// Each entry as readable RFC 5322 text, which reads back to the entry:
    /// display names decoded, and quoted only where address syntax needs it.
    private static func text(of entries: [AddressListEntry]) -> [String] {
        entries.map { AddressFormatter.string(for: $0, form: .display) }
    }

    /// The entries of address text, each string holding any number of them.
    private static func entries(parsing texts: [String]) -> [AddressListEntry] {
        texts.flatMap(AddressParser.parseAddressList)
    }
}
