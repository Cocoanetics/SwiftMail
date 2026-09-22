import NIOIMAPCore

extension Collection where Element == Capability {
    /// IMAP capability tokens are ASCII case-insensitive, while NIOIMAPCore
    /// preserves their spelling and synthesizes case-sensitive equality.
    func containsCapabilityIgnoringCase(_ capability: Capability) -> Bool {
        let expected = String(capability).uppercased()
        return contains { String($0).uppercased() == expected }
    }
}
