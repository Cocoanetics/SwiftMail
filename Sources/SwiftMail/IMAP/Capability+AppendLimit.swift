import NIOIMAPCore

extension Set where Element == NIOIMAPCore.Capability {
    /// Returns the global server-wide APPENDLIMIT in bytes, if advertised.
    ///
    /// Per RFC 7889, a server may advertise `APPENDLIMIT=<n>` (with a numeric value) in its
    /// CAPABILITY response to declare the maximum accepted APPEND payload size. A bare
    /// `APPENDLIMIT` (without a value) indicates per-mailbox limits only and does **not**
    /// impose a global ceiling — this property returns `nil` in that case.
    var globalAppendLimit: Int? {
        for cap in self where cap.name == "APPENDLIMIT" {
            if let value = cap.value, let limit = Int(value) {
                return limit
            }
        }
        return nil
    }
}
