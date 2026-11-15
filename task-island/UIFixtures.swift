import Foundation

/// Isolated GUI scenarios. No source observers, external navigation or ledger writes.
enum UIFixture {
    static let names = ["empty", "review-one", "review-many", "review-resumed", "unconfirmed", "missing-link", "offline", "long-title", "running", "input"]
    @MainActor static func apply(_ name: String, to model: LiveModel) {
        let now = LiveModel.milliseconds()
        func task(_ suffix: String, _ state: LiveState = .review, _ key: String? = "result:fixture-one") -> LiveTask {
            LiveTask(id: "codex:fixture-" + suffix, provider: "codex", title: suffix == "one" ? "Verify search results" : "Review interface updates",
                     state: state, resultKey: key, sourceURL: "codex://threads/fixture-" + suffix + "?hostId=durable",
                     observedAt: now, evidence: "live", updatedAt: now)
        }
        func snapshot(_ tasks: [LiveTask]) {
            model.apply(LiveSnapshot(type: "snapshot", version: 1, generatedAt: LiveModel.milliseconds(),
                providers: [.init(id: "codex", health: "live"), .init(id: "claude", health: "offline")], tasks: tasks))
        }
        switch name {
        case "empty": snapshot([])
        case "review-many": snapshot([task("one"), task("two")])
        case "review-resumed": snapshot([task("one")]); snapshot([task("one", .running, nil)])
        case "unconfirmed": snapshot([task("one", .review, nil)])
        case "missing-link": var row = task("one"); row.sourceURL = nil; snapshot([row])
        case "offline": snapshot([task("one")]); model.disconnected()
        case "long-title": var row = task("one"); row.title = String(String(repeating: "A long task title to check that actions remain visible. ", count: 20).prefix(500)); snapshot([row])
        case "running": snapshot([task("one", .running, nil)]); model.selection = .running
        case "input": snapshot([task("one", .input, nil)]); model.selection = .input
        default: snapshot([task("one")])
        }
    }
}
