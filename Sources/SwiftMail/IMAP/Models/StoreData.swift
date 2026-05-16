// StoreData.swift
// Model for IMAP STORE command data

import Foundation
import NIOIMAPCore

/// Represents the data for an IMAP STORE command
public struct StoreData {
    /// The type of store operation
    public enum StoreType {
        case add
        case remove
        case replace

        /// Convert to NIO StoreType
        func toNIO() -> NIOIMAPCore.StoreOperation {
            switch self {
                case .add:
                    .add
                case .remove:
                    .remove
                case .replace:
                    .replace
            }
        }
    }

    /// The flags to store
    public let flags: [Flag]

    /// The type of store operation
    public let storeType: StoreType

    /// Initialize with flags and store type
    /// - Parameters:
    ///   - flags: The flags to store
    ///   - storeType: The type of store operation
    public init(flags: [Flag], storeType: StoreType) {
        self.flags = flags
        self.storeType = storeType
    }

    /// Factory method for creating a StoreData with flags
    /// - Parameters:
    ///   - flags: The flags to store
    ///   - storeType: The type of store operation
    /// - Returns: A new StoreData instance
    public static func flags(_ flags: [Flag], _ storeType: StoreType) -> StoreData {
        StoreData(flags: flags, storeType: storeType)
    }

    /// Convert to NIOIMAPCore.StoreData
    public func toNIO() -> NIOIMAPCore.StoreData {
        // Convert flags to NIOIMAPCore.Flag array
        let nioFlags = flags.map { $0.toNIO() }

        // Create and return NIOIMAPCore.StoreData with the appropriate operation and flags
        // Using the proper factory methods on StoreFlags
        let storeFlags = switch storeType {
            case .add:
                NIOIMAPCore.StoreFlags.add(silent: false, list: nioFlags)
            case .remove:
                NIOIMAPCore.StoreFlags.remove(silent: false, list: nioFlags)
            case .replace:
                NIOIMAPCore.StoreFlags.replace(silent: false, list: nioFlags)
        }
        return .flags(storeFlags)
    }
}
