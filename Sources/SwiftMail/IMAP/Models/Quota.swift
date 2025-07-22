import Foundation
import NIOIMAPCore

/// Represents a single quota resource like STORAGE or MESSAGE count.
public struct QuotaResource: Codable, Sendable {
    /// The resource name, e.g. "STORAGE" or "MESSAGE".
    public var resourceName: String
    /// How much of the resource is currently used.
    public var usage: Int
    /// The maximum value allowed for the resource.
    public var limit: Int

    /// Create a new quota resource
    public init(resourceName: String, usage: Int, limit: Int) {
        self.resourceName = resourceName
        self.usage = usage
        self.limit = limit
    }

    /// Create from NIOIMAPCore representation
    internal init(from nio: NIOIMAPCore.QuotaResource) {
        self.resourceName = nio.resourceName
        self.usage = nio.usage
        self.limit = nio.limit
    }
}

/// Represents the quota for a specific quota root.
public struct Quota: Codable, Sendable {
    /// The name of the quota root.
    public var quotaRoot: String
    /// Quota resources belonging to the root.
    public var resources: [QuotaResource]

    /// Create a new quota
    public init(quotaRoot: String, resources: [QuotaResource]) {
        self.quotaRoot = quotaRoot
        self.resources = resources
    }

    /// Create from NIOIMAPCore representation
    internal init(root: NIOIMAPCore.QuotaRoot, resources: [NIOIMAPCore.QuotaResource]) {
        self.quotaRoot = String(root) ?? ""
        self.resources = resources.map { QuotaResource(from: $0) }
    }
}
