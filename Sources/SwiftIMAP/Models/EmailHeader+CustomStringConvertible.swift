import Foundation

extension EmailHeader: CustomStringConvertible {
    public var description: String {
        """
        From: \(from)
        Date: \(date.formattedForDisplay())
        """
    }
} 
