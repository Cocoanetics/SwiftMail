import Foundation

extension Header: CustomStringConvertible {
    public var description: String {
        """
        From: \(from)
        Subject: \(subject)
        Date: \(date.formattedForDisplay())
        """
    }
} 
