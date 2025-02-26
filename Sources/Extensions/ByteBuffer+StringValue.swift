// ByteBuffer+StringValue.swift
// Extension to provide string representation of ByteBuffer

import Foundation
import NIO

extension ByteBuffer {
    /// Get a String representation of the ByteBuffer
    var stringValue: String {
        getString(at: readerIndex, length: readableBytes) ?? ""
    }
} 