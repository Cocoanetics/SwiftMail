// MessageID+StringValue.swift
// Extension to provide string representation of MessageID

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

extension MessageID {
    /// Get a String representation of the MessageID
    var stringValue: String {
        String(describing: self)
    }
} 