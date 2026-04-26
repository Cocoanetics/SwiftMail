import NIOIMAPCore

extension Set where Element == NIOIMAPCore.Capability {
    func supportsSort(criteria: [SortCriterion]) -> Bool {
        guard !criteria.isEmpty else { return false }

        if criteria.contains(where: \.requiresDisplaySortCapability) {
            return self.contains(.sort(.display))
        }

        return self.contains(.sort(nil)) || self.contains(.sort(.display))
    }
}
