import Foundation
import OrderedCollections

/// Client or server identification information used with the IMAP `ID` command.
///
/// The most common fields defined by RFC 2971 are provided as stored
/// properties. Additional parameters that do not match these fields can
/// be accessed via the subscript operator.
public struct Identification: Sendable {
    /// Product name of the client or server.
    public var name: String?
    /// Product version string.
    public var version: String?
    /// Operating system name.
    public var os: String?
    /// Operating system version string.
    public var osVersion: String?
    /// Name of the vendor.
    public var vendor: String?
    /// Support contact URL.
    public var supportURL: String?

    /// Any additional parameters returned by the server.
    public var additional: [String: String?]

    /// Create a new identification value.
    public init(
        name: String? = nil,
        version: String? = nil,
        os: String? = nil,
        osVersion: String? = nil,
        vendor: String? = nil,
        supportURL: String? = nil,
        additional: [String: String?] = [:]
    ) {
        self.name = name
        self.version = version
        self.os = os
        self.osVersion = osVersion
        self.vendor = vendor
        self.supportURL = supportURL
        self.additional = additional
    }

    /// Create an Identification from raw parameters received from NIOIMAP.
    internal init(parameters: OrderedDictionary<String, String?>) {
        self.name = parameters["name"] ?? nil
        self.version = parameters["version"] ?? nil
        self.os = parameters["os"] ?? nil
        self.osVersion = parameters["os-version"] ?? nil
        self.vendor = parameters["vendor"] ?? nil
        self.supportURL = parameters["support-url"] ?? nil
        var other: [String: String?] = [:]
        for (key, value) in parameters where !Self.knownKeys.contains(key) {
            other[key] = value
        }
        self.additional = other
    }

    /// Access a parameter by key.
    public subscript(key: String) -> String? {
        switch key {
        case "name": return name
        case "version": return version
        case "os": return os
        case "os-version": return osVersion
        case "vendor": return vendor
        case "support-url": return supportURL
        default: return additional[key] ?? nil
        }
    }

    /// Convert this Identification into the ordered dictionary format expected by NIOIMAP.
    internal var nioParameters: OrderedDictionary<String, String?> {
        var params: OrderedDictionary<String, String?> = [:]
        params["name"] = name
        params["version"] = version
        params["os"] = os
        params["os-version"] = osVersion
        params["vendor"] = vendor
        params["support-url"] = supportURL
        for (k, v) in additional {
            params[k] = v
        }
        return params
    }

    /// Keys that map directly to stored properties.
    private static let knownKeys: Set<String> = [
        "name", "version", "os", "os-version", "vendor", "support-url"
    ]
}
