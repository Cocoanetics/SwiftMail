import Testing
import NIOIMAPCore
@testable import SwiftMail

struct ExtendedSearchPlanTests {
    private let range = PartialRange.first(1...100)

    @Test
    func esearchWithoutPartialDropsTheWindow() {
        // Gmail / iCloud: ESEARCH advertised, PARTIAL not — RETURN (... PARTIAL ...) is a BAD.
        let caps: Set<Capability> = [.extendedSearch]
        let plan = caps.extendedSearchPlan(useSort: false, partialRange: range)
        #expect(plan.useEsearch)
        #expect(plan.partialRange == nil)
    }

    @Test
    func esearchWithPartialKeepsTheWindow() {
        let caps: Set<Capability> = [.extendedSearch, .partial]
        let plan = caps.extendedSearchPlan(useSort: false, partialRange: range)
        #expect(plan.useEsearch)
        #expect(plan.partialRange != nil)
    }

    @Test
    func noEsearchMeansPlainSearch() {
        let plan = Set<Capability>().extendedSearchPlan(useSort: false, partialRange: range)
        #expect(!plan.useEsearch)
        #expect(plan.partialRange == nil)
    }

    @Test
    func sortWithoutPartialFallsBackToPlainSort() {
        let caps: Set<Capability> = [.extendedSearch]
        let plan = caps.extendedSearchPlan(useSort: true, partialRange: range)
        #expect(!plan.useEsearch)
    }
}
