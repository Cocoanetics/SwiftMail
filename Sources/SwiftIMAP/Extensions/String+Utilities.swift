// String+Utilities.swift
// Extensions for String to handle IMAP-related utilities

import Foundation
import NIOIMAPCore

extension String {
    /// Parse a string range (e.g., "1:10") into a SequenceSet
    /// - Returns: A SequenceSet object
    /// - Throws: An error if the range string is invalid
    func toSequenceSet() throws -> NIOIMAPCore.MessageIdentifierSetNonEmpty<NIOIMAPCore.SequenceNumber> {
        // Split the range by colon
        let parts = self.split(separator: ":")
        
        if parts.count == 1, let number = UInt32(parts[0]) {
            // Single number
            let sequenceNumber = SequenceNumber(number)
            let set = SequenceNumberSet(sequenceNumber)
            return set.toNIOSet()!
        } else if parts.count == 2, let start = UInt32(parts[0]), let end = UInt32(parts[1]) {
            // Range
            let startSeq = SequenceNumber(start)
            let endSeq = SequenceNumber(end)
            let set = SequenceNumberSet(startSeq...endSeq)
            return set.toNIOSet()!
        } else {
            throw IMAPError.invalidArgument("Invalid sequence range: \(self)")
        }
    }
} 
