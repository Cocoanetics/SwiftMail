import Foundation
import NIOCore

/**
 Command to send EHLO and retrieve server capabilities
 */
struct EHLOCommand: SMTPCommand {
    /// The result type is the raw response text
    typealias ResultType = String

    /// The handler type that will process responses for this command
    typealias HandlerType = EHLOHandler

    /// Timeout in seconds for EHLO command (typically quick to respond)
    let timeoutSeconds: Int = 30

    /// The client identity to use for the EHLO command
    let clientIdentity: String

    /// Initialize a new EHLO command
    /// - Parameter clientIdentity: The RFC 5321 domain or address literal to use for the EHLO command
    init(clientIdentity: String) {
        self.clientIdentity = clientIdentity
    }

    /// Convert the command to a string that can be sent to the server
    func toCommandString() -> String {
        return "EHLO \(clientIdentity)"
    }

    /// Reject malformed identities before they can alter the SMTP command stream.
    func validate() throws {
        let bytes = clientIdentity.utf8
        guard (1...255).contains(bytes.count),
            bytes.allSatisfy({ (33...126).contains($0) }),
            Self.isValidDomain(Array(bytes)) || Self.isValidAddressLiteral(Array(bytes)) else {
            throw SMTPError.commandFailed(
                "EHLO client identity must be an RFC 5321 domain or address literal "
                    + "of at most 255 ASCII octets"
            )
        }
    }

    private static func isValidDomain(_ bytes: [UInt8]) -> Bool {
        let labels = bytes.split(separator: 0x2E, omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            guard (1...63).contains(label.count),
                let first = label.first,
                let last = label.last,
                isLetterOrDigit(first),
                isLetterOrDigit(last) else {
                return false
            }
            return label.allSatisfy { isLetterOrDigit($0) || $0 == 0x2D }
        }
    }

    private static func isValidAddressLiteral(_ bytes: [UInt8]) -> Bool {
        guard bytes.first == 0x5B, bytes.last == 0x5D else {
            return false
        }

        let contents = bytes.dropFirst().dropLast()
        if isValidIPv4Address(contents) {
            return true
        }

        let ipv6Prefix = Array("IPv6:".utf8)
        if contents.count > ipv6Prefix.count,
            zip(contents, ipv6Prefix).allSatisfy({ asciiEqualIgnoringCase($0, $1) }) {
            guard let address = String(
                bytes: contents.dropFirst(ipv6Prefix.count),
                encoding: .utf8
            ) else {
                return false
            }
            return address.contains(":") && (try? SocketAddress(ipAddress: address, port: 0)) != nil
        }
        return false
    }

    private static func isValidIPv4Address(_ bytes: ArraySlice<UInt8>) -> Bool {
        let components = bytes.split(separator: 0x2E, omittingEmptySubsequences: false)
        guard components.count == 4 else {
            return false
        }
        return components.allSatisfy { component in
            guard (1...3).contains(component.count), component.allSatisfy({ (48...57).contains($0) }) else {
                return false
            }
            let value = component.reduce(0) { result, byte in
                result * 10 + Int(byte - 48)
            }
            return value <= 255
        }
    }

    private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func asciiEqualIgnoringCase(_ lhs: UInt8, _ rhs: UInt8) -> Bool {
        lhs == rhs || (lhs ^ 0x20) == rhs
    }
}
