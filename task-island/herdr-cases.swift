import Foundation

private struct HerdrFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class HerdrEventRecorder {
    var events: [AttentionEvent] = []
    init(_ model: LiveModel) {
        model.onAttentionEvent = { [self] in events.append($0) }
    }
}

@main
struct HerdrCases {
    @MainActor static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("task-island-herdr-cases-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let now = LiveModel.milliseconds()
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw HerdrFailure(description: message) }
        }
        func model(_ name: String) -> LiveModel {
            LiveModel(stateDirectory: base.appendingPathComponent(name), persist: false)
        }
        func herdr(_ state: LiveState, result: String? = nil, url: String? = nil) -> LiveTask {
            LiveTask(id: "herdr:build-box/t16", provider: "herdr", title: "build-box · Synthetic", state: state,
                     resultKey: result, sourceURL: url, observedAt: now, evidence: "live", updatedAt: now)
        }
        func snapshot(_ rows: [LiveTask], at: Double = now) -> LiveSnapshot {
            LiveSnapshot(type: "snapshot", version: 1, generatedAt: at,
                         providers: [ProviderState(id: "codex", health: "live"), ProviderState(id: "claude", health: "live"),
                                     ProviderState(id: "herdr", health: "live")],
                         tasks: rows)
        }
        var passed = 0
        func run(_ name: String, _ body: () throws -> Void) throws {
            try body(); passed += 1; print("PASS: " + name)
        }

        try run("A three-provider snapshot with a Herdr review is accepted") {
            let m = model("accept")
            m.apply(snapshot([herdr(.review)]), nowMs: now)
            try require(m.connectionLabel != "Offline", "Snapshot with herdr must not disconnect")
            try require(m.pendingReviewGroups.count == 1, "Herdr review must be listed in Review")
            try require(m.count(.review, provider: .herdr) == 1, "Herdr review must count under its provider")
        }
        try run("A Herdr review cannot be marked reviewed in Monita") {
            let m = model("unmarkable")
            m.apply(snapshot([herdr(.review)]), nowMs: now)
            guard let group = m.pendingReviewGroups.first else { throw HerdrFailure(description: "missing group") }
            try require(!m.canMarkReviewed(group), "Reviewed must be unavailable for Herdr")
            m.markReviewed(group)
            try require(m.pendingReviewGroups.count == 1, "markReviewed must not clear a Herdr review")
        }
        try run("Viewing in Herdr clears the review") {
            let m = model("clears")
            m.apply(snapshot([herdr(.review)]), nowMs: now)
            m.apply(snapshot([herdr(.read)], at: now + 1), nowMs: now + 1)
            try require(m.pendingReviewGroups.isEmpty, "Read in Herdr must leave Review")
        }
        try run("Herdr rows with a result key or URL are rejected") {
            let keyed = model("keyed")
            keyed.apply(snapshot([herdr(.review, result: "result:1")]), nowMs: now)
            try require(keyed.connectionLabel == "Offline", "A herdr result key must be rejected")
            let linked = model("linked")
            linked.apply(snapshot([herdr(.review, url: "claude://code/session_x")]), nowMs: now)
            try require(linked.connectionLabel == "Offline", "A herdr URL must be rejected")
        }
        try run("Herdr completion and input play attention events once") {
            let m = model("attention")
            let recorder = HerdrEventRecorder(m)
            m.apply(snapshot([herdr(.running)]), nowMs: now)
            try require(recorder.events.isEmpty, "First sight is a baseline")
            m.apply(snapshot([herdr(.review)], at: now + 1), nowMs: now + 1)
            try require(recorder.events == [.completed], "running → review must sound completion")
            m.apply(snapshot([herdr(.review)], at: now + 2), nowMs: now + 2)
            try require(recorder.events == [.completed], "review → review must stay quiet")
            m.apply(snapshot([herdr(.running)], at: now + 3), nowMs: now + 3)
            m.apply(snapshot([herdr(.error)], at: now + 4), nowMs: now + 4)
            try require(recorder.events == [.completed, .completed], "running → error must sound completion")
            m.apply(snapshot([herdr(.input)], at: now + 5), nowMs: now + 5)
            try require(recorder.events == [.completed, .completed, .input], "→ input must sound input")
        }
        try run("Herdr can be opened without a URL") {
            try require(LiveModel.canOpen(herdr(.review)), "Herdr opens the app")
            let claude = LiveTask(id: "claude:local_x", provider: "claude", title: "c", state: .read, resultKey: nil,
                                  sourceURL: nil, observedAt: now, evidence: "live", updatedAt: now)
            try require(!LiveModel.canOpen(claude), "Claude without a URL cannot open")
            var linked = claude; linked.sourceURL = "claude://code/continue?session=local_x"
            try require(LiveModel.canOpen(linked), "Claude with a URL opens")
        }
        print("All \(passed) Herdr cases passed")
    }
}
