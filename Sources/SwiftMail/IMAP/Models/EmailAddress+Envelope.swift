// EmailAddress+Envelope.swift
// Structured addresses from an IMAP ENVELOPE address list element.

import Foundation
import NIOIMAPCore

extension EmailAddress {
    /// Convert an ENVELOPE address into structured ``EmailAddress`` values.
    ///
    /// Groups are flattened to their member addresses — no synthetic address is
    /// produced for the group name itself. An address with neither a mailbox nor
    /// a host is dropped rather than yielding a bare `"@"`.
    ///
    /// This deliberately diverges from the legacy string formatting, which
    /// unconditionally renders `"\(mailbox)@\(host)"` (so a mailbox-only address
    /// becomes `"devnull@"` and an empty one becomes `"@"`). Those are display
    /// artefacts that make sense only in a free-text string; a structured address
    /// with no mailbox and no host carries no information, so it is omitted.
    /// - Parameter address: The address to convert
    /// - Returns: The structured addresses contributed by this element
    static func structured(_ address: EmailAddressListElement) -> [EmailAddress] {
        structuredOrNil(address) ?? []
    }

    /// A whole ENVELOPE address list, or `[]` if any address in it is unsafe:
    /// a structured list is either complete or empty, so callers that prefer
    /// it never silently lose a recipient the legacy strings still carry.
    static func structuredList(_ addresses: [EmailAddressListElement]) -> [EmailAddress] {
        var result: [EmailAddress] = []
        for address in addresses {
            guard let converted = structuredOrNil(address) else { return [] }
            result += converted
        }
        return result
    }

    /// Whether an address can go into a header field as-is: no control
    /// character a field body may not hold literally (see
    /// ``isForbiddenInFieldBody(_:)``).
    static func isHeaderSafe(_ address: String) -> Bool {
        !address.unicodeScalars.contains(where: isForbiddenInFieldBody)
    }

    /// A C0 control other than HTAB, or DEL: never legal literally in a header
    /// field body. CR and LF would end the field and start an injected one, and
    /// some readers treat other controls (VT, FF) as line breaks too. HTAB is
    /// legal whitespace, e.g. inside a quoted local-part.
    static func isForbiddenInFieldBody(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value < 0x20 && scalar != "\t") || scalar.value == 0x7F
    }

    /// `nil` when an address is unsafe (see ``isHeaderSafe(_:)``).
    private static func structuredOrNil(_ address: EmailAddressListElement) -> [EmailAddress]? {
        switch address {
            case .singleAddress(let emailAddress):
                let name = emailAddress.personName?.stringValue.decodeMIMEHeader() ?? ""
                let mailbox = emailAddress.mailbox?.stringValue ?? ""
                let host = emailAddress.host?.stringValue ?? ""

                let value: String
                switch (mailbox.isEmpty, host.isEmpty) {
                    case (false, false):
                        value = "\(mailbox)@\(host)"
                    case (false, true):
                        value = mailbox
                    case (true, false):
                        value = "@\(host)"
                    case (true, true):
                        return []
                }
                guard isHeaderSafe(value) else { return nil }

                return [EmailAddress(name: name.isEmpty ? nil : name, address: value)]

            case .group(let group):
                var members: [EmailAddress] = []
                for child in group.children {
                    guard let converted = structuredOrNil(child) else { return nil }
                    members += converted
                }
                return members
        }
    }
}
