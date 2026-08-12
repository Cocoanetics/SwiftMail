// HeaderField.swift

/// A single RFC 5322 header field instance, preserving wire order and repeated values.
public struct HeaderField: Codable, Hashable, Sendable {
    /// Lowercased field name, matching the key convention used in ``MessageInfo/additionalFields``.
    public let name: String

    /// Unfolded, trimmed field value.
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}
