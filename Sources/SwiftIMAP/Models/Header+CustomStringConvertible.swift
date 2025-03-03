import Foundation

extension Header: CustomStringConvertible {
    public var description: String {
        """
        From: \(from)
        Date: \(date.formattedForDisplay())
        """
    }
} 
