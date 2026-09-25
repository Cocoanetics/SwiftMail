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

                return [EmailAddress(name: name.isEmpty ? nil : name, address: value)]

            case .group(let group):
                return group.children.flatMap(structured)
        }
    }
}
