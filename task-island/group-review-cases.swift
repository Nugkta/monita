import Foundation

private struct GroupFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct GroupReviewCases {
    @MainActor static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("task-island-group-cases-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let now = LiveModel.milliseconds()
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw GroupFailure(description: message) }
        }
        func model(_ name: String, persist: Bool = false) -> LiveModel {
            LiveModel(stateDirectory: base.appendingPathComponent(name), persist: persist)
        }
        func task(_ id: String = "sample-task", provider: TaskProvider = .codex,
                  state: LiveState = .review, result: String? = "result:turn-1") -> LiveTask {
            LiveTask(id: id, provider: provider.rawValue, title: "Synthetic " + id,
                     state: state, resultKey: result, sourceURL: nil,
                     observedAt: now, evidence: "live", updatedAt: now)
        }
        func snapshot(_ tasks: [LiveTask]) -> LiveSnapshot {
            LiveSnapshot(type: "snapshot", version: 1, generatedAt: now,
                         providers: [ProviderState(id: "codex", health: "live"), ProviderState(id: "claude", health: "live")],
                         tasks: tasks)
        }
        var passed = 0
        func run(_ name: String, _ body: () throws -> Void) throws {
            try body(); passed += 1; print("PASS: " + name)
        }

        try run("multiple pending results from one task make one task badge") {
            let m = model("group-count")
            m.apply(snapshot([task()]), nowMs: now)
            m.apply(snapshot([task(result: "result:turn-2")]), nowMs: now)
            try require(m.pendingResults.count == 2 && m.count(.review) == 1 && m.count(.review, provider: .codex) == 1,
                        "Result identities must remain separate while the badge counts their task only once")
            let group = m.currentReviewGroup!
            try require(group.items.count == 2 && group.task.resultKey == "result:turn-2" &&
                        m.pendingReviewGroups.count == 1, "Group must display the latest captured result")
        }
        try run("confirming a captured task group immediately clears all its shown results") {
            let m = model("group-ack")
            m.apply(snapshot([task()]), nowMs: now)
            m.apply(snapshot([task(result: "result:turn-2")]), nowMs: now)
            let group = m.currentReviewGroup!
            try require(m.canMarkReviewed(group), "Confirmed captured task group must be reviewable")
            m.markReviewed(group)
            try require(m.pendingResults.isEmpty && m.count(.review) == 0 && m.currentReviewGroup == nil,
                        "A task-level confirmation must update the badge and visible queue synchronously")
            m.apply(snapshot([task(result: "result:turn-2")]), nowMs: now)
            try require(m.count(.review) == 0, "Repeated source snapshot must not recreate acknowledged results")
        }
        try run("new result arriving after group capture remains pending after confirmation") {
            let m = model("group-race")
            m.apply(snapshot([task()]), nowMs: now)
            m.apply(snapshot([task(result: "result:turn-2")]), nowMs: now)
            let captured = m.currentReviewGroup!
            m.apply(snapshot([task(result: "result:turn-3")]), nowMs: now)
            m.markReviewed(captured)
            try require(m.pendingResults.count == 1 && m.count(.review) == 1 &&
                        m.currentReviewGroup?.task.resultKey == "result:turn-3",
                        "A stale group button must acknowledge only captured completion identities")
        }
        try run("reviewed labels belong to the exact provider and current result identity") {
            let m = model("reviewed-label-scope")
            let codex = task("shared-task")
            let claude = task("shared-task", provider: .claude)
            m.apply(snapshot([codex, claude]), nowMs: now)
            try require(!m.isResultReviewed(codex) && !m.isResultReviewed(claude),
                        "Pending results must not show a reviewed label")
            m.markReviewed(m.reviewGroups(for: .codex)[0])
            try require(m.isResultReviewed(codex) && !m.isResultReviewed(claude),
                        "A confirmed Codex result must not label Claude's identical task/result as reviewed")
            let newCodex = task("shared-task", result: "result:turn-2")
            m.apply(snapshot([newCodex, claude]), nowMs: now)
            try require(!m.isResultReviewed(newCodex) && m.isResultReviewed(codex) &&
                        m.count(.review, provider: .codex) == 1,
                        "A newer result must return to pending without losing the older exact receipt")
        }
        try run("provider metadata remains distinct inside one combined panel") {
            let m = model("provider-counts")
            m.apply(snapshot([task("codex-review"), task("codex-running", state: .running, result: nil),
                              task("claude-review", provider: .claude), task("claude-input", provider: .claude, state: .input, result: nil)]), nowMs: now)
            try require(m.count(.review, provider: .codex) == 1 && m.count(.review, provider: .claude) == 1 &&
                        m.count(.running, provider: .codex) == 1 && m.count(.running, provider: .claude) == 0 &&
                        m.count(.input, provider: .claude) == 1 && m.count(.input, provider: .codex) == 0,
                        "Provider status counters must never mix Codex and Claude")
            try require(m.tasks.count == 4 && m.pendingReviewGroups.count == 2 && m.count(.review) == 2,
                        "Combined panel must contain both providers without double-counting task results")
            try require(m.tasks(for: .codex).count == 2 && m.tasks(for: .codex).allSatisfy { $0.provider == "codex" } &&
                        m.tasks(for: .claude).count == 2 && m.tasks(for: .claude).allSatisfy { $0.provider == "claude" },
                        "Per-provider helpers must preserve labels without requiring separate panels")
        }
        try run("same task IDs across providers cannot share review groups or receipts") {
            let m = model("provider-collision")
            m.apply(snapshot([task("shared-task"), task("shared-task", provider: .claude)]), nowMs: now)
            let codex = m.reviewGroups(for: .codex)[0]
            let claude = m.reviewGroups(for: .claude)[0]
            try require(codex.id != claude.id && m.count(.review) == 2,
                        "Review grouping identity must include provider")
            m.markReviewed(codex)
            try require(m.count(.review, provider: .codex) == 0 && m.count(.review, provider: .claude) == 1 &&
                        m.pendingResults.count == 1 && m.pendingResults[0].task.provider == "claude",
                        "A Codex group receipt must not acknowledge a Claude task")
        }
        try run("next cycles every counted task group across both providers") {
            let m = model("provider-next")
            m.apply(snapshot([task("codex-first"), task("claude-first", provider: .claude), task("codex-second")]), nowMs: now)
            var visited = Set<String>()
            for _ in 0..<m.count(.review) {
                visited.insert(m.currentReviewGroup!.id); m.skipReviewGroup()
            }
            try require(visited == Set(m.pendingReviewGroups.map(\.id)),
                        "Next must reach every counted task from both providers")
        }
        try run("selecting another provider's task invalidates in-flight navigation feedback") {
            let m = model("provider-navigation")
            m.expanded = true
            m.apply(snapshot([task(), task("claude-task", provider: .claude)]), nowMs: now)
            let request = m.beginNavigation(m.currentReviewGroup!.task)
            m.selectReviewGroup(m.reviewGroups(for: .claude)[0])
            try require(!m.finishNavigation(success: true, generation: request) && m.navigationFeedback == nil &&
                        m.navigationSuccessCount == 0 && m.currentReviewGroup?.task.provider == "claude" && m.expanded,
                        "Codex completion callback must not change or collapse the Claude panel")
        }
        try run("mixed confirmed and unconfirmed updates cannot be acknowledged as a complete task") {
            let m = model("unconfirmed-group")
            m.apply(snapshot([task()]), nowMs: now)
            m.apply(snapshot([task(result: nil)]), nowMs: now)
            let group = m.currentReviewGroup!
            try require(group.items.count == 2 && !m.canMarkReviewed(group),
                        "Unknown completion identity must disable whole-group confirmation")
            m.markReviewed(group)
            try require(m.pendingResults.count == 2 && m.count(.review) == 1,
                        "Disabled task confirmation must not erase either known or unknown update")
        }
        try run("source read and resumed activity do not silently acknowledge a grouped task") {
            let m = model("source-read-group")
            m.apply(snapshot([task()]), nowMs: now)
            m.apply(snapshot([task(result: "result:turn-2")]), nowMs: now)
            m.apply(snapshot([task(state: .read, result: "result:turn-2")]), nowMs: now)
            try require(m.count(.review) == 1 && m.currentReviewGroup?.items.count == 2,
                        "Source-read receipt is distinct from explicit grouped review confirmation")
            m.apply(snapshot([task(state: .running, result: nil)]), nowMs: now)
            try require(m.count(.running, provider: .codex) == 1 && m.count(.review, provider: .codex) == 1,
                        "Previous results must remain inspectable while their task runs again")
        }
        try run("group confirmations and remaining provider queue survive restart") {
            let m = model("restart", persist: true)
            m.apply(snapshot([task(), task("claude-task", provider: .claude)]), nowMs: now)
            m.apply(snapshot([task(result: "result:turn-2"), task("claude-task", provider: .claude)]), nowMs: now)
            m.markReviewed(m.currentReviewGroup!)
            let reloaded = model("restart", persist: true)
            try require(reloaded.count(.review, provider: .codex) == 0 && reloaded.count(.review, provider: .claude) == 1,
                        "Grouped receipts must persist without hiding the other provider's queue")
            reloaded.apply(snapshot([task(result: "result:turn-2"), task("claude-task", provider: .claude)]), nowMs: now)
            try require(reloaded.count(.review) == 1 && reloaded.count(.review, provider: .codex) == 0,
                        "Acknowledged historical completion must not requeue on reconnect")
        }
        print("PASS: \(passed) grouped review/provider scenarios; synthetic metadata only; no source apps or real ledger used.")
    }
}
