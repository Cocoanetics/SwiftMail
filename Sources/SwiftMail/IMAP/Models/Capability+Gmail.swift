import NIOIMAPCore

extension Set where Element == NIOIMAPCore.Capability {
    /// Gmail's `X-GM-EXT-1` follows the same case-insensitive token rules as MOVE
    /// and UIDPLUS; a server or proxy may spell it `x-gm-ext-1`.
    var containsGmailExtensionsCapability: Bool {
        containsBareCapability(named: "x-gm-ext-1")
    }
}
