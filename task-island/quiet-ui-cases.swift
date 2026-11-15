import Foundation

private struct QuietFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct QuietUICases {
    @MainActor static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("task-island-quiet-cases-" + UUID().uuidString)
        let now = LiveModel.milliseconds()
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw QuietFailure(description: message) }
        }
        func model(_ name: String) -> LiveModel {
            LiveModel(stateDirectory: base.appendingPathComponent(name), persist: false)
        }
        func cached(_ id: String = "claude:session_fixture", state: LiveState = .unknown,
                    observed: Double, last: LiveState? = .running, evidence: String = "history",
                    provider: String = "claude", tag: String? = "claude-cache") -> LiveTask {
            LiveTask(id: id, provider: provider, title: "Synthetic cached task", state: state,
                     resultKey: nil, sourceURL: nil, observedAt: observed, evidence: evidence, updatedAt: observed,
                     observationSource: tag, lastObservedState: last)
        }
        func live(_ id: String, state: LiveState = .running, result: String? = nil) -> LiveTask {
            LiveTask(id: id, provider: "codex", title: "Synthetic live task", state: state,
                     resultKey: result, sourceURL: nil, observedAt: now, evidence: "live", updatedAt: now)
        }
        func snapshot(_ tasks: [LiveTask], at: Double = now) -> LiveSnapshot {
            LiveSnapshot(type: "snapshot", version: 1, generatedAt: at,
                         providers: [ProviderState(id: "codex", health: "live"), ProviderState(id: "claude", health: "degraded")],
                         tasks: tasks)
        }
        var passed = 0
        func run(_ name: String, _ body: () throws -> Void) throws {
            try body(); passed += 1; print("PASS: " + name)
        }

        try run("stale explicit Claude activity stays visible without becoming live or reviewed") {
            let m = model("recent-stale")
            let row = cached(observed: now - 30_000)
            m.apply(snapshot([row]), nowMs: now)
            try require(!m.isStale && m.displayState(row) == .unknown && m.count(.running) == 0,
                        "A current bridge heartbeat cannot make a stale Claude observation a running task")
            try require(m.recentActivity == [row] && m.claudeStatusDelayed,
                        "Previously observed explicit running activity must remain discoverable as delayed")
            try require(m.count(.review) == 0 && m.pendingResults.isEmpty &&
                        m.diagnostics()["knownCompletionCount"] as? Int == 0 && row.resultKey == nil,
                        "A last-running annotation cannot manufacture a result identity or review receipt")
            try require(m.observationAgeSeconds(row) == 30, "The UI must disclose the original observation age")
        }
        try run("fresh heartbeats preserve old observation age and delayed status") {
            let m = model("age-heartbeat")
            let row = cached(observed: now - 30_000)
            m.apply(snapshot([row]), nowMs: now)
            m.apply(snapshot([row], at: now + 10_000), nowMs: now + 10_000)
            try require(m.observationAgeSeconds(row) == 40 && m.recentActivity.first?.observedAt == row.observedAt &&
                        m.count(.running) == 0 && m.claudeStatusDelayed,
                        "Repeated reads must not renew the source's activity timestamp")
        }
        try run("fresh live Claude observation replaces its delayed row and counts once") {
            let m = model("recent-recovered")
            m.apply(snapshot([cached(observed: now - 30_000)]), nowMs: now)
            let fresh = cached(state: .running, observed: now + 1_000, evidence: "live")
            m.apply(snapshot([fresh], at: now + 1_000), nowMs: now + 1_000)
            try require(m.displayState(fresh) == .running && m.count(.running) == 1 && m.recentActivity.isEmpty &&
                        !m.claudeStatusDelayed && m.count(.review) == 0,
                        "Recovery must replace the historical row rather than duplicate it or create a completion")
        }
        try run("Claude live activity independently expires despite a fresh bridge heartbeat") {
            let m = model("independent-expiry")
            let row = cached(state: .running, observed: now, evidence: "live")
            m.apply(snapshot([row]), nowMs: now)
            try require(m.count(.running) == 1 && m.recentActivity.isEmpty, "The original fresh sample must count")
            m.apply(snapshot([row], at: now + 20_001), nowMs: now + 20_001)
            try require(!m.isStale && m.count(.running) == 0 && m.recentActivity == [row] &&
                        m.claudeStatusDelayed && m.observationAgeSeconds(row) == 20,
                        "A fresh app connection must still expire old per-task observations")
        }
        try run("foreign providers and untagged records cannot inject last-observed activity") {
            for row in [cached("codex:fixture", observed: now - 30_000, provider: "codex"),
                        cached(observed: now - 30_000, tag: nil)] {
                let m = model("invalid-provider-" + UUID().uuidString)
                m.apply(snapshot([row]), nowMs: now)
                try require(m.isStale && m.tasks.isEmpty && m.recentActivity.isEmpty && !m.claudeStatusDelayed,
                            "Only explicitly tagged Claude cache records may carry historical activity")
            }
        }
        try run("last-observed completion or unknown states are rejected as activity claims") {
            for last in [LiveState.review, .read, .error, .unknown] {
                let m = model("invalid-state-" + last.rawValue)
                m.apply(snapshot([cached(observed: now - 30_000, last: last)]), nowMs: now)
                try require(m.isStale && m.tasks.isEmpty && m.count(.review) == 0,
                            "Historical activity cannot be used to smuggle source-read or completion evidence")
            }
        }
        try run("idle history stays quiet while explicit input history remains discoverable") {
            let m = model("idle-and-input")
            let idle = cached("claude:session_idle", observed: now - 30_000, last: .idle)
            let input = cached("claude:session_input", observed: now - 40_000, last: .input)
            m.apply(snapshot([idle]), nowMs: now)
            try require(m.recentActivity.isEmpty && !m.claudeStatusDelayed,
                        "Historical idle records must not create a warning about missed activity")
            m.apply(snapshot([idle, input]), nowMs: now)
            try require(m.recentActivity == [input] && m.count(.input) == 0 && m.count(.review) == 0,
                        "Input history may be inspected but cannot be reported as a current input request")
        }
        try run("invalid observation times never appear in recent activity") {
            let m = model("time-bounds")
            let zero = cached("claude:session_zero", observed: 0)
            let future = cached("claude:session_future", observed: now + 1_000)
            m.apply(snapshot([zero, future]), nowMs: now)
            try require(m.recentActivity.isEmpty && !m.claudeStatusDelayed,
                        "An absent or future observation has no usable historical age")
        }
        try run("review panel heights count task groups and stop growing after three rows") {
            let m = model("review-heights")
            m.selection = .review
            try require(m.preferredPanelHeight == 148, "Empty review keeps a small readable empty state")
            m.apply(snapshot([live("codex:one", state: .review, result: "result:one")]), nowMs: now)
            try require(m.preferredPanelHeight == 148, "A single task uses one quiet row")
            m.apply(snapshot([live("codex:one", state: .review, result: "result:two")]), nowMs: now)
            try require(m.pendingResults.count == 2 && m.preferredPanelHeight == 148,
                        "Another result from the same task must not enlarge the panel")
            m.apply(snapshot([live("codex:two", state: .review, result: "result:one")]), nowMs: now)
            try require(m.preferredPanelHeight == 210, "Two task groups use two rows")
            m.apply(snapshot([live("codex:three", state: .review, result: "result:one")]), nowMs: now)
            try require(m.preferredPanelHeight == 272, "Three task groups reach the compact height ceiling")
            m.apply(snapshot([live("codex:four", state: .review, result: "result:one")]), nowMs: now)
            try require(m.count(.review) == 4 && m.preferredPanelHeight == 272,
                        "Additional task groups must scroll instead of growing the window")
        }
        try run("running and all panel heights include historical activity without double counting fresh rows") {
            let m = model("running-heights")
            m.selection = .running
            let one = live("codex:running-one")
            let two = live("codex:running-two")
            let old = cached(observed: now - 30_000)
            m.apply(snapshot([one]), nowMs: now)
            try require(m.preferredPanelHeight == 148, "A single confirmed running task uses one row")
            m.apply(snapshot([one, old]), nowMs: now)
            try require(m.count(.running) == 1 && m.preferredPanelHeight == 210,
                        "A delayed activity row needs space without becoming a live count")
            m.apply(snapshot([one, two, old]), nowMs: now)
            try require(m.preferredPanelHeight == 272, "Two running tasks and one delayed row fit at the ceiling")
            m.selection = .all
            try require(m.preferredPanelHeight == 272, "All uses the same displayed-row ceiling")
            let fresh = cached(state: .running, observed: now, evidence: "live")
            m.apply(snapshot([one, fresh]), nowMs: now)
            try require(m.recentActivity.isEmpty && m.count(.running) == 2 && m.preferredPanelHeight == 210,
                        "A fresh recovered row must not reserve both a live and a delayed slot")
        }
        try run("old records decode without a historical activity annotation") {
            let row = cached(observed: now - 30_000)
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as! [String: Any]
            object.removeValue(forKey: "lastObservedState")
            let restored = try JSONDecoder().decode(LiveTask.self, from: JSONSerialization.data(withJSONObject: object))
            let m = model("old-record")
            m.apply(snapshot([restored]), nowMs: now)
            try require(restored.lastObservedState == nil && m.recentActivity.isEmpty && !m.claudeStatusDelayed,
                        "Older records must not invent an unrecorded activity history")
        }
        try run("a task last seen running is shown as unconfirmed, never counted as running, and ages out") {
            let m = model("unconfirmed-running")
            let running = cached("claude:session_running", observed: now - 60_000, last: .running)
            let input = cached("claude:session_input", observed: now - 60_000, last: .input)
            let idle = cached("claude:session_idle", observed: now - 60_000, last: .idle)
            let ancient = cached("claude:session_ancient", observed: now - 7_200_001, last: .running)
            m.apply(snapshot([running, input, idle, ancient]), nowMs: now)
            try require(m.count(.running) == 0, "A stale observation never becomes a confirmed running task")
            try require(m.unconfirmedRunningCount == 1,
                        "Only the task last seen running, within two hours, is offered as unconfirmed")
            let fresh = cached("claude:session_running", state: .running, observed: now + 1_000, evidence: "live")
            m.apply(snapshot([fresh, ancient], at: now + 1_000), nowMs: now + 1_000)
            try require(m.count(.running) == 1 && m.unconfirmedRunningCount == 0,
                        "A fresh observation is counted once, as confirmed")
            m.tick(nowMs: now + 22_000)
            try require(m.count(.running) == 0 && m.unconfirmedRunningCount == 1,
                        "When the observation expires the task returns to unconfirmed instead of vanishing")
        }
        try run("the reveal follows expansion at rest and the pinned value while the panel moves") {
            let m = model("reveal")
            try require(m.reveal == 0 && m.revealMotion == nil, "Compact at rest")
            m.expanded = true
            try require(m.reveal == 1, "Open at rest")
            m.revealMotion = RevealMotion(progress: 0.4, bodyWidth: 440, bodyHeight: 114, bodyShift: -60)
            try require(m.reveal == 0.4, "A pinned value wins while moving")
            m.revealMotion?.progress = 1.7
            try require(m.reveal == 1, "The content never sees a value outside 0...1")
            m.revealMotion = nil; m.expanded = false
            try require(m.reveal == 0, "Back to rest")
        }
        print("PASS: \(passed) quiet-panel and delayed-activity scenarios; synthetic metadata only; no source apps or real ledger used.")
    }
}
