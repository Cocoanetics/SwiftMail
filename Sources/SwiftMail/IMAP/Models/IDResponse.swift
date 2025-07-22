import Foundation
import OrderedCollections

/// Information returned by the IMAP `ID` command.
///
/// The server may return any key/value pairs describing its
/// implementation. Values may be `nil` if the server omits them.
public struct IDResponse: Sendable {
    /// Raw key/value pairs returned by the server.
    public var parameters: OrderedDictionary<String, String?>

    /// Create a new response with the provided parameters.
    public init(parameters: OrderedDictionary<String, String?> = [:]) {
        self.parameters = parameters
    }

    /// Access a value by key.
    public subscript(key: String) -> String? {
        parameters[key] ?? nil
    }

    /// Commonly used name field of the server.
    public var name: String? { self["name"] }

    /// Server version string if provided.
    public var version: String? { self["version"] }
}
