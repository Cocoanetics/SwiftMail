import NIOIMAPCore

extension Set where Element == NIOIMAPCore.Capability {
    /// RFC 3501 capability names are ASCII case-insensitive, while
    /// NIOIMAPCore preserves their spelling and synthesizes case-sensitive equality.
    var containsMoveCapability: Bool {
        containsBareCapability(named: "move")
    }

    /// RFC 4315's UIDPLUS capability follows the same case-insensitive token rules.
    var containsUIDPlusCapability: Bool {
        containsBareCapability(named: "uidplus")
    }

    /// RFC 7162 CONDSTORE, matched as a case-insensitive bare token.
    var containsCondStoreCapability: Bool {
        containsBareCapability(named: "condstore")
    }

    /// RFC 7162 QRESYNC, matched as a case-insensitive bare token.
    var containsQResyncCapability: Bool {
        containsBareCapability(named: "qresync")
    }

    /// Case-insensitive membership test for a value-less capability token,
    /// shared by every `supports…` accessor on both connection surfaces.
    func containsBareCapability(named expectedName: String) -> Bool {
        contains { capability in
            guard capability.value == nil else { return false }
            return capability.name.utf8.elementsEqual(expectedName.utf8) { candidate, expected in
                (candidate | 0x20) == expected
            }
        }
    }
}
