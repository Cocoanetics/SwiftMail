import NIOIMAPCore

extension Set<NIOIMAPCore.Capability> {
    func supportsSort(criteria: [SortCriterion]) -> Bool {
        guard !criteria.isEmpty else { return false }

        if criteria.contains(where: \.requiresDisplaySortCapability) {
            return contains(.sort(.display))
        }

        return contains(.sort(nil)) || contains(.sort(.display))
    }
}
