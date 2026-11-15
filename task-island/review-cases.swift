import Foundation

private struct CaseFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct ReviewCases {
    @MainActor
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("task-island-review-cases-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let now = LiveModel.milliseconds()
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CaseFailure(description: message) }
        }
        func model(_ name: String, persist: Bool = false) -> LiveModel {
            LiveModel(stateDirectory: base.appendingPathComponent(name), persist: persist)
        }
        func task(_ id: String = "codex:sample-task", provider: String = "codex",
                  state: LiveState = .review, result: String? = "result:turn-1",
                  url: String? = nil, evidence: String = "live", at: Double? = nil) -> LiveTask {
            LiveTask(id: id, provider: provider, title: "Synthetic " + id, state: state,
                     resultKey: result, sourceURL: url, observedAt: at ?? now,
                     evidence: evidence, updatedAt: at ?? now)
        }
        func snapshot(_ rows: [LiveTask], at: Double? = nil) -> LiveSnapshot {
            LiveSnapshot(type: "snapshot", version: 1, generatedAt: at ?? now,
                         providers: [ProviderState(id: "codex", health: "live"), ProviderState(id: "claude", health: "live")],
                         tasks: rows)
        }
        var passed: [String] = []
        func run(_ name: String, _ body: () throws -> Void) throws {
            try body(); passed.append(name); print("PASS: " + name)
        }

        try run("first source-read observation establishes a baseline") {
            let m = model("baseline")
            m.apply(snapshot([task(state: .read)]), nowMs: now)
            try require(m.count(.review) == 0, "Historical source-read must not fill review queue")
        }
        try run("running and input transitions lead to an inspectable completion") {
            let m = model("transitions")
            m.apply(snapshot([task(state: .running, result: nil)]), nowMs: now)
            try require(m.count(.running) == 1 && m.count(.review) == 0, "Running must not create a result")
            m.apply(snapshot([task(state: .input, result: nil)]), nowMs: now)
            try require(m.count(.input) == 1 && m.count(.running) == 0, "Input must replace running")
            m.apply(snapshot([task()]), nowMs: now)
            try require(m.currentResult?.task.title == "Synthetic codex:sample-task" && m.count(.review) == 1,
                        "Review badge must refer to a titled result")
        }
        try run("source-read state cannot clear an unreviewed completion") {
            let m = model("source-read")
            m.apply(snapshot([task()]), nowMs: now)
            let identity = m.currentResult?.id
            m.apply(snapshot([task(state: .read)]), nowMs: now)
            try require(m.currentResult?.id == identity && m.count(.review) == 1, "Opening elsewhere must not acknowledge review")
        }
        try run("resumed work leaves Review while running and returns, unacknowledged, when it stops") {
            let m = model("resumed")
            m.apply(snapshot([task()]), nowMs: now)
            let old = m.currentResult!
            m.apply(snapshot([task(state: .running, result: nil)]), nowMs: now)
            try require(m.count(.running) == 1 && m.count(.review) == 0 && m.pendingReviewGroups.isEmpty && m.currentResult == nil,
                        "A running task must not also be listed in Review")
            try require(m.pendingResults.map(\.id) == [old.id], "Hiding is not acknowledging: the result stays queued")
            m.apply(snapshot([task(state: .idle, result: nil)]), nowMs: now)
            try require(m.count(.running) == 0 && m.count(.review) == 1 && m.currentResult?.id == old.id && m.isHistorical(old),
                        "Once it stops, the earlier result is back in Review, still to be reviewed")
        }
        try run("a stale running observation does not hide a result") {
            let m = model("stale-running")
            m.apply(snapshot([task()]), nowMs: now)
            m.apply(snapshot([task(state: .running, result: nil)]), nowMs: now)
            m.disconnected()
            try require(m.count(.running) == 0 && m.count(.review) == 1,
                        "Only confirmed running hides a result; unknown state shows it")
        }
        try run("acknowledging a captured older result never clears the newer result") {
            let m = model("rapid")
            m.apply(snapshot([task()]), nowMs: now)
            let old = m.currentResult!
            m.apply(snapshot([task(result: "result:turn-2")]), nowMs: now)
            try require(m.count(.review) == 1 && m.pendingResults.count == 2,
                        "Two completion identities remain separate within one counted task")
            m.markReviewed(old)
            try require(m.count(.review) == 1 && m.currentResult?.task.resultKey == "result:turn-2",
                        "Stale button capture must acknowledge only its own result")
        }
        try run("selection is stable while another task completes and next cycles all entries") {
            let m = model("selection")
            m.apply(snapshot([task(), task("codex:second-task")]), nowMs: now)
            m.skip()
            let selected = m.currentResult!.id
            m.apply(snapshot([task(), task("codex:second-task"), task("codex:third-task")]), nowMs: now)
            try require(m.currentResult?.id == selected, "New incoming completion must not steal selection")
            var visited = Set<String>()
            for _ in 0..<m.count(.review) { visited.insert(m.currentResult!.id); m.skip() }
            try require(visited == Set(m.pendingResults.map(\.id)), "Next must reach every counted result")
        }
        try run("provider namespaces prevent review receipt collisions") {
            let m = model("namespace")
            m.apply(snapshot([task("shared-task"), task("shared-task", provider: "claude")]), nowMs: now)
            try require(m.count(.review) == 2, "Same external identity across providers must remain distinct")
            let codex = m.pendingResults.first { $0.task.provider == "codex" }!
            m.markReviewed(codex)
            try require(m.count(.review) == 1 && m.currentResult?.task.provider == "claude",
                        "Codex receipt must never acknowledge Claude")
        }
        try run("missing navigation URLs keep a named review item available") {
            let m = model("no-url")
            m.apply(snapshot([task(url: nil)]), nowMs: now)
            try require(m.currentResult?.task.sourceURL == nil && m.currentResult?.task.title.isEmpty == false,
                        "No-link completion must remain identifiable in the queue")
            try require(m.canMarkReviewed(m.currentResult!), "Verified completion identity remains reviewable after manual lookup")
        }
        try run("errors have their own confirmed completion identity") {
            let m = model("error")
            m.apply(snapshot([task(state: .error, result: "error:failed-turn")]), nowMs: now)
            try require(m.count(.review) == 1 && m.currentResult?.task.state == .error,
                        "Confirmed failure must be inspectable without being counted as running")
        }
        try run("disconnect stops runtime counts and preserves confirmed results") {
            let m = model("disconnect")
            m.apply(snapshot([task(), task("codex:running-task", state: .running, result: nil)]), nowMs: now)
            m.disconnected()
            try require(m.count(.running) == 0 && m.count(.review) == 1 && m.isHistorical(m.currentResult!),
                        "Disconnect must retain review metadata without claiming live runtime")
        }
        try run("removed source rows do not erase pending completion metadata") {
            let m = model("removed")
            m.apply(snapshot([task()]), nowMs: now)
            m.apply(snapshot([]), nowMs: now)
            try require(m.count(.all) == 0 && m.count(.review) == 1 && m.isHistorical(m.currentResult!),
                        "A retained historical result must remain inspectable when its task disappears")
        }
        try run("restart preserves queue, explicit receipts and private ledger permissions") {
            let name = "restart"
            let m = model(name, persist: true)
            m.apply(snapshot([task(), task("codex:second-task")]), nowMs: now)
            let acknowledged = m.currentResult!
            m.markReviewed(acknowledged)
            let reloaded = model(name, persist: true)
            try require(reloaded.count(.review) == 1, "Pending result must survive restart")
            reloaded.apply(snapshot([task(), task("codex:second-task")]), nowMs: now)
            try require(reloaded.count(.review) == 1 && !reloaded.pendingResults.contains { $0.id == acknowledged.id },
                        "Acknowledged completion must not requeue")
            let path = base.appendingPathComponent(name).appendingPathComponent("review-ledger.json").path
            let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber
            try require(mode.intValue == 0o600, "Review ledger must use private file permissions")
        }
        try run("corrupt ledger is preserved and review acknowledgments are disabled") {
            let dir = base.appendingPathComponent("corrupt")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent("review-ledger.json")
            let original = Data("synthetic-invalid-ledger".utf8)
            try original.write(to: path)
            let m = model("corrupt", persist: true)
            m.apply(snapshot([task()]), nowMs: now)
            try require(m.ledgerError != nil && !m.canMarkReviewed(m.currentResult!), "Corruption must disable confirmation")
            let preserved = try Data(contentsOf: path)
            try require(preserved == original, "Corrupt ledger must not be overwritten")
        }
        try run("unconfirmed completion is inspectable but cannot be acknowledged") {
            let m = model("unconfirmed")
            m.apply(snapshot([task(result: nil)]), nowMs: now)
            try require(m.count(.review) == 1 && !m.canMarkReviewed(m.currentResult!), "Missing result identity must disable confirmation")
            m.markReviewed()
            try require(m.count(.review) == 1, "Disabled confirmation must not erase the update")
        }
        try run("cached idle and cached expiration never create review receipts") {
            let m = model("cache")
            var cached = task("claude:session_example", provider: "claude", state: .idle, result: nil)
            cached.observationSource = "claude-cache"
            m.apply(snapshot([cached]), nowMs: now)
            try require(m.count(.review) == 0, "Cached idle must not mean an unread result")
            m.apply(snapshot([cached], at: now + 21_000), nowMs: now + 21_000)
            try require(m.displayState(cached) == .unknown && m.count(.review) == 0, "New heartbeat must not refresh stale cached observations")
        }
        try run("wrong-task destinations fail closed without erasing retained results") {
            let m = model("wrong-url")
            m.apply(snapshot([task()]), nowMs: now)
            m.apply(snapshot([task(url: "codex://threads/other-task?hostId=durable")]), nowMs: now)
            try require(m.isStale && m.count(.review) == 1, "Wrong destination must not be used or erase pending metadata")
        }
        try run("review selection and next discard stale navigation callbacks") {
            let m = model("navigation-selection")
            m.expanded = true
            m.apply(snapshot([task(), task("codex:second-task")]), nowMs: now)
            let first = m.currentResult!
            let second = m.pendingResults.first { $0.id != first.id }!
            let firstAttempt = m.beginNavigation(first.task)
            m.selectReview(second.id)
            try require(!m.finishNavigation(success: true, synthetic: true, generation: firstAttempt),
                        "Opening an earlier item must not complete after selecting another result")
            try require(m.navigationSuccessCount == 0 && m.navigationFeedback == nil &&
                        m.currentResult?.id == second.id && m.expanded,
                        "Stale success must not change selection, show success or permit collapse")
            let secondAttempt = m.beginNavigation(second.task)
            m.skip()
            try require(!m.finishNavigation(success: false, generation: secondAttempt) &&
                        m.navigationFeedback == nil && m.currentResult?.id == first.id && m.expanded,
                        "Next must cancel both success and failure feedback from the previous item")
        }
        try run("section changes and explicit review cancel in-flight navigation") {
            let m = model("navigation-lifecycle")
            m.expanded = true
            m.apply(snapshot([task(), task("codex:second-task")]), nowMs: now)
            let first = m.currentResult!
            let beforeSectionChange = m.beginNavigation(first.task)
            m.selection = .running
            try require(!m.finishNavigation(success: true, generation: beforeSectionChange) &&
                        m.navigationSuccessCount == 0 && m.navigationFeedback == nil && m.expanded,
                        "A delayed callback must not collapse or overwrite a newly selected section")
            m.selection = .review
            let beforeReview = m.beginNavigation(first.task)
            m.markReviewed(first)
            try require(!m.finishNavigation(success: true, generation: beforeReview) &&
                        m.navigationSuccessCount == 0 && m.navigationFeedback == nil &&
                        m.count(.review) == 1 && m.currentResult?.id != first.id && m.expanded,
                        "Acknowledgment must invalidate opening callbacks for the removed result")
        }
        try run("new navigation attempts supersede old ones and only current success is accepted") {
            let m = model("navigation-generation")
            m.expanded = true
            m.apply(snapshot([task()]), nowMs: now)
            let item = m.currentResult!
            let oldAttempt = m.beginNavigation(item.task)
            let currentAttempt = m.beginNavigation(item.task)
            try require(!m.finishNavigation(success: true, generation: oldAttempt) &&
                        m.navigationFeedback == "Opening original task..." && m.navigationSuccessCount == 0,
                        "An older request must not replace the active request's progress")
            try require(m.finishNavigation(success: false, generation: currentAttempt) &&
                        m.navigationFeedback?.contains("Cannot open the original task") == true && m.expanded,
                        "Current failure must keep the panel open with actionable feedback")
            let retry = m.beginNavigation(item.task)
            try require(m.finishNavigation(success: true, synthetic: true, generation: retry) &&
                        m.navigationSuccessCount == 1 && m.navigationAttemptCount == 3 && m.count(.review) == 1,
                        "Only a current successful retry counts; opening never acknowledges the result")
        }
        print("PASS: \(passed.count) review navigation and lifecycle scenarios; synthetic metadata only; no source applications opened.")
    }
}
