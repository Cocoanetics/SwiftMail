import NIOIMAPCore

extension Set where Element == NIOIMAPCore.Capability {
    /// RFC 3501 capability names are ASCII case-insensitive, while
    /// NIOIMAPCore preserves their spelling and synthesizes case-sensitive equality.
    var containsMoveCapability: Bool {
        contains { capability in
            guard capability.value == nil else { return false }
            return capability.name.utf8.elementsEqual("move".utf8) { candidate, expected in
                (candidate | 0x20) == expected
            }
        }
    }
}
