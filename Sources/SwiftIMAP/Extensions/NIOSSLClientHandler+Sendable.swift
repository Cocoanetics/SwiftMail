// NIOSSLClientHandler+Sendable.swift
// Extension to make NIOSSLClientHandler conform to Sendable

import Foundation
import NIOSSL

// Add a file-level extension to make NIOSSLClientHandler conform to Sendable
// Note: This will generate a warning about conforming an imported type to an imported protocol,
// but it's necessary to suppress the Sendable warnings in the code
extension NIOSSLClientHandler: @unchecked @retroactive Sendable {} 