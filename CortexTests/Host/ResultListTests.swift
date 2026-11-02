import Testing
@testable import Cortex

/// The selection rules every palette list shares.
@MainActor
@Suite struct ResultListTests {
    let list = ResultList<String, String>(id: { $0 })

    @Test func aNewQuerySelectsTheFirstResult() {
        list.replace(with: ["a", "b", "c"], query: "")
        list.move(by: 2)
        #expect(list.selected == "c")

        list.replace(with: ["b", "c"], query: "x")
        #expect(list.selected == "b")
    }

    @Test func theSameQueryKeepsTheSelection() {
        list.replace(with: ["a", "b", "c"], query: "")
        list.move(by: 1)
        list.replace(with: ["new", "a", "b", "c"], query: "")
        #expect(list.selected == "b")
    }

    @Test func aRemovedItemSelectsItsNeighbour() {
        list.replace(with: ["a", "b", "c"], query: "")
        list.move(by: 1)
        list.replace(with: ["a", "c"], query: "")
        #expect(list.selected == "c")

        list.replace(with: ["a"], query: "")
        #expect(list.selected == "a", "the last one removed: the new last")
    }

    @Test func movingStopsAtEitherEnd() {
        list.replace(with: ["a", "b"], query: "")
        list.move(by: -1)
        #expect(list.selected == "a")
        list.move(by: 5)
        #expect(list.selected == "b")
    }

    @Test func reportsSelectionChanges() {
        var selected: [String?] = []
        list.didSelect = { selected.append($0) }
        list.replace(with: ["a", "b"], query: "")
        list.select("a")
        list.move(by: 1)
        #expect(selected == ["a", "b"])
    }

    @Test func aNewerSearchWins() async {
        let slow = list.load(query: "slow") {
            try await Task.sleep(for: .seconds(5))
            return ["slow"]
        }
        await list.load(query: "fast") { ["fast"] }.value
        await slow.value
        #expect(list.items == ["fast"])
        #expect(list.hasLoaded)
    }

    @Test func clearingDropsEverything() {
        list.replace(with: ["a"], query: "")
        list.clear()
        #expect(list.items.isEmpty)
        #expect(list.selectedID == nil)
        #expect(!list.hasLoaded)
    }
}
