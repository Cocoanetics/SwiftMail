import NIOIMAP
import NIOIMAPCore

/// Enables connection-local IMAP extensions advertised by the server.
struct EnableCommand: IMAPTaggedCommand {
    typealias ResultType = [Capability]
    typealias HandlerType = EnableHandler

    let capabilities: [Capability]

    func validate() throws {
        guard !capabilities.isEmpty else {
            throw IMAPError.invalidArgument("At least one capability must be requested")
        }

        guard capabilities.allSatisfy({ Self.isValidCapabilityAtom(String($0)) }) else {
            throw IMAPError.invalidArgument("Capabilities must be nonempty ASCII IMAP atoms")
        }
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        TaggedCommand(tag: tag, command: .enable(capabilities))
    }

    private static func isValidCapabilityAtom(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }

        return value.utf8.allSatisfy { byte in
            switch byte {
                case 0x22, 0x25, 0x28, 0x29, 0x2A, 0x5C, 0x5D, 0x7B:
                    return false
                case 0x21...0x7E:
                    return true
                default:
                    return false
            }
        }
    }
}
