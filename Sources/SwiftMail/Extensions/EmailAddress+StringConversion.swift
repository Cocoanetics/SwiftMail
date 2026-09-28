// EmailAddress+StringConversion.swift
// EmailAddress to and from RFC 5322 text, through AddressParser and AddressFormatter.

import Foundation

// MARK: - LosslessStringConvertible conformance for EmailAddress

extension EmailAddress: LosslessStringConvertible {
    /**
     Initialize an email address from its RFC 5322 text

     Accepts one mailbox: `Name <address>`, `<address>`, or a bare `address`, with
     everything RFC 5322 allows around them (see ``AddressParser``). The display
     name comes back as the text it stands for: quoted-pairs resolved, and a
     *bare* encoded-word decoded, which is how a non-ASCII name written by
     ``description`` or read off the wire arrives. Inside a *quoted-string* an
     encoded-word look-alike is literal text (RFC 2047 §5).

     As the text is one mailbox and never a list, a display name may hold an
     unquoted comma (`Doe, Jane <jane@example.com>`), and it may break the
     phrase grammar in other ways mail commonly does, as long as a well-formed
     `<address>` ends the text and the name names no other address.

     - Parameter description: The text of exactly one mailbox. A group, a list of
       addresses, or malformed text yields `nil`.
     */
    public init?(_ description: String) {
        guard let address = AddressParser.parseMailbox(description) else { return nil }
        self = address
    }

    /**
     Get the string representation of the email address

     This is the RFC 5322 address string, including the display name if there is
     one — the same text ``headerString()`` writes into a header field, and the
     text ``init(_:)`` reads back to the identical address. A name that address
     syntax cannot carry literally is RFC 2047-encoded; see ``headerString()``
     for which names those are and why. Emitting a name raw when it holds a CR
     or LF is what let a `Message` built from an `Email` grow a header field its
     author never wrote.
     */
    public var description: String { headerString() }

    /**
     RFC 5322 address string for use in a header field (`From`/`To`/`Cc`/…).

     A display name that cannot be written literally is RFC 2047-encoded. That
     covers two cases:

     - The name is not a valid field body — it holds non-ASCII text or a control
       character. A CR or LF here *ends the header field*, so an unencoded name
       turns the rest of the value into new header lines.
     - The name holds a `"` or a `\`, the two characters that would escape the
       quoted-string it would otherwise be wrapped in.

     An encoded-word may replace a word inside a phrase (RFC 2047 §5) and its
     output is bare printable ASCII, so encoding carries the name intact. An
     encoded name is emitted bare, never quoted: a quoted-string always carries
     a literal. Any other name is quoted unless it is plain words, so its white
     space and punctuation survive, and the address never carries a control
     character (see ``AddressFormatter``).
     */
    func headerString() -> String {
        AddressFormatter.string(for: self, form: .header)
    }

    /// The address as readable RFC 5322 text: like ``headerString()``, but with
    /// a non-ASCII display name kept as UTF-8 (RFC 6532), and `"` and `\`
    /// escaped inside a quoted-string. ``init(_:)`` reads it back to the
    /// identical address.
    var displayString: String {
        AddressFormatter.string(for: self, form: .display)
    }
}
