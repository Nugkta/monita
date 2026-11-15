import Foundation

private struct AttentionFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class EventRecorder {
    var events: [AttentionEvent] = []
    init(_ model: LiveModel) {
        model.onAttentionEvent = { [self] in events.append($0) }
    }
}

@main
struct AttentionEventsCases {
    @MainActor static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("task-island-attention-cases-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let now = LiveModel.milliseconds()
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw AttentionFailure(description: message) }
        }
        func model(_ name: String, persist: Bool = false) -> LiveModel {
            LiveModel(stateDirectory: base.appendingPathComponent(name), persist: persist)
        }
        func task(_ id: String = "sample-task", provider: String = "codex", state: LiveState = .running,
                  result: String? = nil, at: Double? = nil, evidence: String = "live") -> LiveTask {
            LiveTask(id: id, provider: provider, title: "Synthetic " + id, state: state, resultKey: result,
                     sourceURL: nil, observedAt: at ?? now, evidence: evidence, updatedAt: at ?? now)
        }
        func recorded(_ result: String?, state: LiveState = .unknown, at: Double? = nil) -> LiveTask {
            var row = task(provider: "claude", state: state, result: result, at: at,
                           evidence: state == .unknown ? "unavailable" : "live")
            row.completionTracking = LiveModel.turnRecord
            if state == .unknown { row.availabilityReason = "turn-record-only" }
            return row
        }
        func cached(_ state: LiveState, at: Double, last: LiveState? = nil, evidence: String = "live") -> LiveTask {
            var row = task(provider: "claude", state: state, at: at, evidence: evidence)
            row.observationSource = "claude-cache"
            row.lastObservedState = last
            return row
        }
        func snapshot(_ rows: [LiveTask], at: Double? = nil, health: String = "live") -> LiveSnapshot {
            LiveSnapshot(type: "snapshot", version: 1, generatedAt: at ?? now,
                         providers: [ProviderState(id: "codex", health: health), ProviderState(id: "claude", health: health)],
                         tasks: rows)
        }
        var passed = 0
        func run(_ name: String, _ body: () throws -> Void) throws {
            try body(); passed += 1; print("PASS: " + name)
        }

        try run("English labels, connection status and navigation feedback") {
            let m = model("english")
            try require(TaskSection.allCases.map(\.rawValue) == ["Running", "Input", "Review", "All"], "Section labels must be English")
            try require(m.connectionLabel == "Connecting", "Initial connection label")
            m.apply(snapshot([task(state: .review, result: "result:1")]), nowMs: now)
            try require(m.connectionLabel == "Local" && m.currentResult?.task.title == "Synthetic sample-task", "Preserve source titles")
            let generation = m.beginNavigation(m.tasks[0])
            try require(m.navigationFeedback == "Opening original task...", "Opening feedback")
            _ = m.finishNavigation(success: true, generation: generation)
            try require(m.navigationFeedback == "Original task opened. Review history is unchanged.", "Success feedback")
            let synthetic = m.beginNavigation(m.tasks[0])
            _ = m.finishNavigation(success: true, synthetic: true, generation: synthetic)
            try require(m.navigationFeedback == "Test: correct task found. No real session opened.", "Synthetic navigation feedback")
            let failure = m.beginNavigation(m.tasks[0])
            _ = m.finishNavigation(success: false, generation: failure)
            try require(m.navigationFeedback == "Cannot open the original task. Copy its title and search in the source app.", "Failure feedback")
            m.markReviewed(m.currentReviewGroup!)
            try require(m.reviewFeedback == "Confirmed 1 update. Counts are up to date.", "Singular review feedback")
            m.apply(snapshot([task(state: .unknown, evidence: "unavailable")]), nowMs: now)
            try require(m.connectionLabel == "Partial", "Partial connection label")
            m.disconnected()
            try require(m.connectionLabel == "Offline", "Offline connection label")
        }
        try run("completion, repeat, source-read and explicit review are distinct") {
            let m = model("completion")
            let r = EventRecorder(m)
            m.apply(snapshot([task()]), nowMs: now)
            try require(r.events.isEmpty, "Running baseline must be silent")
            m.apply(snapshot([task(state: .review, result: "result:1")]), nowMs: now)
            try require(r.events == [.completed] && m.pendingResults.count == 1, "New queued result must emit once")
            m.apply(snapshot([task(state: .review, result: "result:1")]), nowMs: now)
            m.apply(snapshot([task(state: .read, result: "result:1")]), nowMs: now)
            let generation = m.beginNavigation(m.currentResult!.task)
            _ = m.finishNavigation(success: true, synthetic: true, generation: generation)
            m.skip(); m.skipReviewGroup(); m.selectReviewGroup(m.currentReviewGroup!)
            m.markReviewed(m.currentReviewGroup!)
            m.apply(snapshot([task(state: .review, result: "result:1")]), nowMs: now)
            try require(r.events == [.completed] && m.pendingResults.isEmpty, "Heartbeats, navigation and review must not replay events")
            m.apply(snapshot([task(state: .read, result: "result:2")]), nowMs: now)
            try require(r.events == [.completed, .completed] && m.pendingResults.count == 1, "A genuinely new result can arrive already source-read")
        }
        try run("a source-read baseline returning to review does not announce the same result") {
            let m = model("source-read")
            let r = EventRecorder(m)
            m.apply(snapshot([task(state: .read, result: "result:1")]), nowMs: now)
            m.apply(snapshot([task(state: .review, result: "result:1")]), nowMs: now)
            try require(r.events.isEmpty && m.pendingResults.count == 1, "Source-read changes must preserve queue semantics without sound")
        }
        try run("confirmed failures emit completion events; unconfirmed endings do not") {
            let m = model("error")
            let r = EventRecorder(m)
            m.apply(snapshot([task()]), nowMs: now)
            m.apply(snapshot([task(state: .error)]), nowMs: now)
            try require(r.events.isEmpty && !m.canMarkReviewed(m.currentResult!), "Missing result identity cannot announce completion")
            m.apply(snapshot([task(state: .error, result: "error:1")]), nowMs: now)
            m.apply(snapshot([task(state: .error, result: "error:1")]), nowMs: now)
            try require(r.events == [.completed], "A new confirmed failure emits just once")
        }
        try run("input episodes survive disconnect, unknown, missing rows and stale gaps") {
            let m = model("input")
            let r = EventRecorder(m)
            m.apply(snapshot([task()]), nowMs: now)
            m.apply(snapshot([task(state: .input)]), nowMs: now)
            m.apply(snapshot([task(state: .input)]), nowMs: now)
            m.disconnected()
            m.apply(snapshot([], health: "connecting"), nowMs: now)
            m.apply(snapshot([task(state: .unknown, evidence: "unavailable")]), nowMs: now)
            m.apply(snapshot([task(state: .input)]), nowMs: now)
            m.tick(nowMs: now + 6_000)
            m.apply(snapshot([task(state: .input, at: now + 6_000)], at: now + 6_000), nowMs: now + 6_000)
            try require(r.events == [.input], "Unknown gaps must not resolve an input episode")
            m.apply(snapshot([task(state: .running, at: now + 7_000)], at: now + 7_000), nowMs: now + 7_000)
            m.apply(snapshot([task(state: .input, at: now + 8_000)], at: now + 8_000), nowMs: now + 8_000)
            try require(r.events == [.input, .input], "Confirmed non-input state rearms a later episode")
        }
        try run("unseen initial input and pending results are quiet per task") {
            let m = model("startup")
            let r = EventRecorder(m)
            m.apply(snapshot([], health: "connecting"), nowMs: now)
            m.apply(snapshot([task(state: .input), task("pending-task", state: .review, result: "result:1")]), nowMs: now)
            m.apply(snapshot([task(state: .input), task("pending-task", state: .review, result: "result:1"),
                              task("late-task", state: .input)]), nowMs: now)
            try require(r.events.isEmpty && m.pendingResults.count == 1, "Initial snapshots and newly discovered historical tasks are silent")
            m.apply(snapshot([task(state: .running)]), nowMs: now)
            m.apply(snapshot([task(state: .input)]), nowMs: now)
            try require(r.events == [.input], "A later input episode should announce normally")
        }
        try run("empty connecting snapshots do not swallow genuine first transitions") {
            let m = model("connecting")
            let r = EventRecorder(m)
            m.apply(snapshot([], health: "connecting"), nowMs: now)
            m.apply(snapshot([task(), task("input-task")]), nowMs: now)
            m.apply(snapshot([task(state: .review, result: "result:1"), task("input-task", state: .input)]), nowMs: now)
            try require(r.events == [.completed, .input], "Task baselines must not depend on the first global heartbeat")
        }
        try run("unknown catalog input establishes no false baseline") {
            let m = model("catalog")
            let r = EventRecorder(m)
            m.apply(snapshot([task(state: .input, evidence: "history")]), nowMs: now)
            m.apply(snapshot([task(state: .input)]), nowMs: now)
            try require(r.events.isEmpty, "First confirmed input remains a quiet baseline")
        }
        try run("persisted history and first post-restart snapshots remain quiet") {
            let first = model("restore", persist: true)
            first.apply(snapshot([task(state: .review, result: "result:1"), recorded("result:10")]), nowMs: now)
            let m = model("restore", persist: true)
            let r = EventRecorder(m)
            m.apply(snapshot([], health: "connecting"), nowMs: now)
            m.apply(snapshot([task(state: .review, result: "result:2"), recorded("result:11")]), nowMs: now)
            try require(r.events.isEmpty && m.pendingResults.count == 3, "Restored and historical results keep existing queue semantics silently")
            m.apply(snapshot([task(state: .review, result: "result:3"), recorded("result:12")]), nowMs: now)
            try require(r.events == [.completed] && m.pendingResults.count == 5, "New post-baseline results are batched normally")
        }
        try run("reconnect retains task baselines without suppressing a genuinely new turn") {
            let m = model("reconnect")
            let r = EventRecorder(m)
            m.apply(snapshot([task(state: .review, result: "result:1")]), nowMs: now)
            m.disconnected()
            m.apply(snapshot([], health: "connecting"), nowMs: now)
            m.apply(snapshot([task(state: .review, result: "result:2")]), nowMs: now)
            m.disconnected()
            m.apply(snapshot([task(state: .review, result: "result:2")]), nowMs: now)
            try require(r.events == [.completed] && m.pendingResults.count == 2, "Only the new reconnect result should emit")
        }
        try run("SSH turn records announce new completions with unknown runtime") {
            let m = model("ssh")
            let r = EventRecorder(m)
            m.apply(snapshot([recorded("result:10")]), nowMs: now)
            m.apply(snapshot([recorded("result:11")]), nowMs: now)
            m.apply(snapshot([recorded("result:11")]), nowMs: now)
            try require(r.events == [.completed] && m.count(.running) == 0 && m.pendingResults.count == 1,
                        "Runtime uncertainty must not suppress a newly recorded turn")
            m.markReviewed(m.currentReviewGroup!)
            m.apply(snapshot([recorded("result:11")]), nowMs: now)
            m.disconnected()
            m.apply(snapshot([], health: "connecting"), nowMs: now)
            m.apply(snapshot([recorded("error:12")]), nowMs: now)
            try require(r.events == [.completed, .completed], "New recorded failures survive reconnect deduplication")
        }
        try run("a task observed before its first turn finishes is not swallowed") {
            let m = model("first-turn")
            let r = EventRecorder(m)
            m.apply(snapshot([recorded(nil)]), nowMs: now)
            m.apply(snapshot([recorded("result:1")]), nowMs: now)
            try require(r.events == [.completed] && m.pendingResults.count == 1, "A nil turn record is a valid per-task baseline")
        }
        try run("new recorded turns queue and announce while the task is still running") {
            let m = model("still-running")
            let r = EventRecorder(m)
            m.apply(snapshot([recorded("result:10", state: .running)]), nowMs: now)
            m.apply(snapshot([recorded("result:11", state: .running)]), nowMs: now)
            try require(r.events == [.completed] && m.count(.running) == 1 && m.pendingResults.count == 1,
                        "Completion events follow new queued turn identities, not a terminal runtime state")
        }
        try run("fresh cached active-to-idle endings emit once without a source receipt") {
            let m = model("inferred")
            let r = EventRecorder(m)
            m.apply(snapshot([cached(.running, at: now)]), nowMs: now)
            m.apply(snapshot([cached(.idle, at: now + 1_000)], at: now + 1_000), nowMs: now + 1_000)
            try require(r.events == [.completed] && m.currentResult?.task.completionTracking == LiveModel.observedChange,
                        "New locally inferred ending should emit after queuing")
            m.apply(snapshot([cached(.idle, at: now + 2_000)], at: now + 2_000), nowMs: now + 2_000)
            m.markReviewed(m.currentReviewGroup!)
            m.apply(snapshot([cached(.idle, at: now + 3_000)], at: now + 3_000), nowMs: now + 3_000)
            try require(r.events == [.completed] && m.pendingResults.isEmpty, "Idle repeats and review are silent")
        }
        try run("expired cache input and unknown last-input hints cannot announce input") {
            let m = model("stale-cache")
            let r = EventRecorder(m)
            m.apply(snapshot([cached(.running, at: now)]), nowMs: now)
            m.apply(snapshot([cached(.input, at: now)], at: now + 21_000), nowMs: now + 21_000)
            m.apply(snapshot([cached(.unknown, at: now + 22_000, last: .input, evidence: "unavailable")], at: now + 22_000), nowMs: now + 22_000)
            m.apply(snapshot([cached(.input, at: now + 23_000)], at: now + 23_000), nowMs: now + 23_000)
            try require(r.events == [.input], "Only confirmed fresh input, never stale or last-observed input, can emit")
            m.apply(snapshot([cached(.unknown, at: now + 24_000, last: .idle, evidence: "history")], at: now + 24_000), nowMs: now + 24_000)
            m.apply(snapshot([cached(.input, at: now + 25_000)], at: now + 25_000), nowMs: now + 25_000)
            try require(r.events == [.input, .completed], "A new inferred ending may announce completion, but unknown idle cannot resolve the input episode")
        }
        try run("delayed original cache endings announce once without reviving runtime") {
            let m = model("delayed-inferred")
            let r = EventRecorder(m)
            m.apply(snapshot([cached(.running, at: now)]), nowMs: now)
            var delayed = cached(.unknown, at: now + 1_000, last: .idle, evidence: "history")
            delayed.availabilityReason = "stale-cache"
            m.apply(snapshot([delayed], at: now + 25_000), nowMs: now + 25_000)
            try require(r.events == [.completed] && m.pendingResults.count == 1 && m.displayState(delayed) == .unknown &&
                        m.count(.running) == 0 && m.count(.input) == 0,
                        "A newly queued inferred ending remains valid after its runtime TTL expires")
            m.apply(snapshot([delayed], at: now + 26_000), nowMs: now + 26_000)
            m.disconnected()
            m.apply(snapshot([delayed], at: now + 27_000), nowMs: now + 27_000)
            m.markReviewed(m.currentReviewGroup!)
            m.apply(snapshot([delayed], at: now + 28_000), nowMs: now + 28_000)
            try require(r.events == [.completed] && m.pendingResults.isEmpty, "Repeated delayed snapshots and confirmed endings do not replay")
        }
        try run("delayed cache endings require a newer original idle observation and an available source") {
            let m = model("delayed-source-offline")
            let r = EventRecorder(m)
            m.apply(snapshot([cached(.running, at: now)]), nowMs: now)
            let olderIdle = cached(.unknown, at: now, last: .idle, evidence: "history")
            m.apply(snapshot([olderIdle], at: now + 25_000), nowMs: now + 25_000)
            try require(r.events.isEmpty && m.pendingResults.isEmpty, "An equal or older idle observation is not a new ending")
            var offline = cached(.unknown, at: now + 1_000, last: .idle, evidence: "unavailable")
            offline.availabilityReason = "source-offline"
            m.apply(snapshot([offline], at: now + 26_000), nowMs: now + 26_000)
            try require(r.events.isEmpty && m.pendingResults.count == 1, "Source-offline metadata must not emit even if existing ledger rules infer an ending")
            m.apply(snapshot([cached(.unknown, at: now + 1_000, last: .idle, evidence: "history")], at: now + 27_000), nowMs: now + 27_000)
            try require(r.events.isEmpty, "An ending already queued offline is not newly queued on reconnect")
            let unavailable = model("delayed-provider-offline")
            let outage = EventRecorder(unavailable)
            unavailable.apply(snapshot([cached(.running, at: now)]), nowMs: now)
            unavailable.apply(snapshot([cached(.unknown, at: now + 1_000, last: .idle, evidence: "history")],
                                       at: now + 25_000, health: "offline"), nowMs: now + 25_000)
            try require(outage.events.isEmpty, "Provider outages suppress inferred completion cues")
            let noEvidence = model("delayed-unavailable-evidence")
            let missing = EventRecorder(noEvidence)
            noEvidence.apply(snapshot([cached(.running, at: now)]), nowMs: now)
            noEvidence.apply(snapshot([cached(.unknown, at: now + 1_000, last: .idle, evidence: "unavailable")],
                                      at: now + 25_000), nowMs: now + 25_000)
            try require(missing.events.isEmpty, "Unavailable evidence is not an observed cached completion")
        }
        try run("replayed or expired cached non-input observations cannot rearm input") {
            let m = model("cache-replay")
            let r = EventRecorder(m)
            m.apply(snapshot([cached(.running, at: now)]), nowMs: now)
            m.apply(snapshot([cached(.input, at: now + 1_000)], at: now + 1_000), nowMs: now + 1_000)
            m.apply(snapshot([cached(.running, at: now)], at: now + 2_000), nowMs: now + 2_000)
            m.apply(snapshot([cached(.input, at: now + 1_000)], at: now + 3_000), nowMs: now + 3_000)
            m.apply(snapshot([cached(.running, at: now + 2_000)], at: now + 24_000), nowMs: now + 24_000)
            m.apply(snapshot([cached(.input, at: now + 25_000)], at: now + 25_000), nowMs: now + 25_000)
            try require(r.events == [.input], "Old non-input rows cannot end the current episode")
            m.apply(snapshot([cached(.running, at: now + 26_000)], at: now + 26_000), nowMs: now + 26_000)
            m.apply(snapshot([cached(.input, at: now + 27_000)], at: now + 27_000), nowMs: now + 27_000)
            try require(r.events == [.input, .input], "A later fresh non-input observation rearms normally")
        }
        try run("historical cached activity and restored inferred endings remain quiet") {
            let first = model("cache-restore", persist: true)
            first.apply(snapshot([cached(.running, at: now)]), nowMs: now)
            let m = model("cache-restore", persist: true)
            let r = EventRecorder(m)
            m.apply(snapshot([cached(.idle, at: now + 1_000)], at: now + 1_000), nowMs: now + 1_000)
            try require(r.events.isEmpty && m.pendingResults.count == 1, "Restored active ledger may queue an ending silently")
            let reloaded = model("cache-restore", persist: true)
            let restored = EventRecorder(reloaded)
            reloaded.apply(snapshot([cached(.idle, at: now + 2_000)], at: now + 2_000), nowMs: now + 2_000)
            try require(restored.events.isEmpty && reloaded.pendingResults.count == 1, "Restored inferred pending results are silent")
            let stale = model("cache-history")
            let history = EventRecorder(stale)
            stale.apply(snapshot([cached(.unknown, at: now, last: .running, evidence: "history")], at: now + 21_000), nowMs: now + 21_000)
            stale.apply(snapshot([cached(.idle, at: now + 22_000)], at: now + 22_000), nowMs: now + 22_000)
            try require(history.events.isEmpty && stale.pendingResults.count == 1, "Unseen historical active observation is not an attention baseline")
        }
        try run("provider outages and unavailable evidence cannot emit") {
            let m = model("outage")
            let r = EventRecorder(m)
            m.apply(snapshot([task(), recorded("result:10")]), nowMs: now)
            m.apply(snapshot([task(state: .input), recorded("result:11")], health: "offline"), nowMs: now)
            m.apply(snapshot([task(state: .input, evidence: "unavailable")]), nowMs: now)
            m.apply(snapshot([task(state: .review, result: "result:1", evidence: "history")]), nowMs: now)
            try require(r.events.isEmpty, "Offline or historical sources cannot produce attention events")
            m.apply(snapshot([task(state: .input), recorded("result:11")]), nowMs: now)
            try require(r.events == [.input], "Reconnect confirms input but does not replay a turn already queued offline")
        }
        try run("invalid, outdated and out-of-order snapshots do not announce transitions") {
            let m = model("invalid")
            let r = EventRecorder(m)
            m.apply(snapshot([task()], at: now + 1_000), nowMs: now + 1_000)
            m.apply(snapshot([task(state: .input)]), nowMs: now + 1_000)
            m.apply(snapshot([task(state: .review, result: "result:1")], at: now + 2_000), nowMs: now + 8_000)
            m.apply(snapshot([task(state: .review, result: "not-a-result")], at: now + 8_000), nowMs: now + 8_000)
            m.apply(snapshot([task(state: .input), task(state: .input)], at: now + 8_000), nowMs: now + 8_000)
            try require(r.events.isEmpty && m.pendingResults.isEmpty, "Validation must precede event generation")
            m.apply(snapshot([task(state: .review, result: "result:1")], at: now + 9_000), nowMs: now + 9_000)
            try require(r.events == [.completed], "Rejected snapshots cannot reset a legitimate per-task baseline")
        }
        try run("batched completions and input edges emit at most one event of each kind") {
            let m = model("batch")
            let r = EventRecorder(m)
            m.apply(snapshot([task("same-id"), task("same-id", provider: "claude"), task("input-a"), task("input-b")]), nowMs: now)
            let batch = [task("same-id", state: .review, result: "result:1"),
                         task("same-id", provider: "claude", state: .error, result: "error:1"),
                         task("input-a", state: .input), task("input-b", state: .input)]
            m.apply(snapshot(batch), nowMs: now)
            m.apply(snapshot(batch), nowMs: now)
            try require(r.events == [.completed, .input] && m.pendingResults.count == 2 && m.count(.input) == 2,
                        "Events must be coalesced per snapshot without combining provider identities")
        }
        try run("callbacks observe rebuilt queue and successfully persisted results") {
            let m = model("save-order", persist: true)
            var savedBeforeCallback = false
            var events: [AttentionEvent] = []
            m.onAttentionEvent = { event in
                events.append(event)
                let path = base.appendingPathComponent("save-order/review-ledger.json")
                let data = try? Data(contentsOf: path)
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let rows = json?["pending"] as? [[String: Any]]
                savedBeforeCallback = rows?.count == 1 && m.pendingResults.count == 1
            }
            m.apply(snapshot([task()]), nowMs: now)
            m.apply(snapshot([task(state: .review, result: "result:1")]), nowMs: now)
            try require(events == [.completed] && savedBeforeCallback, "Callbacks must run after the queue is rebuilt and saved")
        }
        try run("failed required persistence suppresses all snapshot attention events") {
            let m = model("save-failure", persist: true)
            let r = EventRecorder(m)
            m.apply(snapshot([task(), task("input-task")]), nowMs: now)
            try FileManager.default.removeItem(at: base.appendingPathComponent("save-failure"))
            m.apply(snapshot([task(state: .review, result: "result:1"), task("input-task", state: .input)]), nowMs: now)
            try require(r.events.isEmpty && m.ledgerError == "Cannot save review history. The original file is unchanged. Review confirmation is unavailable.",
                        "Failed ledger persistence must not emit completion or input")
        }
        try run("corrupt ledger remains untouched and cannot emit attention") {
            let directory = base.appendingPathComponent("corrupt")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let path = directory.appendingPathComponent("review-ledger.json")
            let original = Data("synthetic-invalid-ledger".utf8)
            try original.write(to: path)
            let m = model("corrupt", persist: true)
            let r = EventRecorder(m)
            m.apply(snapshot([task()]), nowMs: now)
            m.apply(snapshot([task(state: .input)]), nowMs: now)
            m.apply(snapshot([task(state: .review, result: "result:1")]), nowMs: now)
            try require(r.events.isEmpty && m.ledgerError == "Cannot read review history. The original file is unchanged. Fix it before retrying.",
                        "Unreadable ledger must fail closed with English feedback")
            let preserved = try Data(contentsOf: path)
            try require(preserved == original, "Corrupt ledger must not be overwritten")
        }
        try run("English plural and captured-review feedback") {
            let m = model("review-feedback")
            m.apply(snapshot([task(state: .review, result: "result:1")]), nowMs: now)
            m.apply(snapshot([task(state: .review, result: "result:2")]), nowMs: now)
            let captured = m.currentReviewGroup!
            m.apply(snapshot([task(state: .review, result: "result:3")]), nowMs: now)
            m.markReviewed(captured)
            try require(m.reviewFeedback == "Confirmed 2 updates. New results still need review." && m.pendingResults.count == 1,
                        "Captured-review feedback should be idiomatic English without changing receipts")
        }
        try runModelSelfChecks()
        print("PASS: \(passed) attention/model English scenarios plus existing model self-checks; isolated synthetic records; no audio or source apps.")
    }
}
