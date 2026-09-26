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

    /// Whether an address can go into a header field as-is: no field-breaking
    /// character (a CR or LF would end the field and start a new one; NUL is
    /// never allowed). Other whitespace, such as an HTAB in a quoted
    /// local-part, is legal.
    static func isHeaderSafe(_ address: String) -> Bool {
        !address.contains { $0 == "\r" || $0 == "\n" || $0 == "\r\n" || $0 == "\0" }
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
