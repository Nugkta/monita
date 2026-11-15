import Foundation
import Combine

enum TaskSection: String, CaseIterable { case running = "Running", input = "Input", review = "Review", all = "All" }
enum TaskProvider: String, CaseIterable { case codex, claude }
enum LiveState: String, Codable { case running, input, review, read, idle, error, unknown }
enum AttentionEvent { case completed, input }

struct LiveTask: Codable, Identifiable, Equatable {
    let id: String
    let provider: String
    var title: String
    let state: LiveState
    let resultKey: String?
    var sourceURL: String?
    let observedAt: Double
    let evidence: String
    let updatedAt: Double
    var observationSource: String? = nil
    var availabilityReason: String? = nil
    var lastObservedState: LiveState? = nil
    /// "turn-record": `resultKey` is the task's own persisted turn identity and is
    /// valid in every state. "observed-change": minted here when a cached row was
    /// seen leaving an active state; an inference, never a source receipt.
    var completionTracking: String? = nil
}
/// Where the expanded body sits while the panel frame is still moving. The body
/// keeps its final size and its final place on screen, and the growing panel
/// uncovers it, so its text is never reflowed or dragged along on the way.
struct RevealMotion: Equatable {
    /// 0 compact, 1 expanded.
    var progress: Double
    /// The body's size once the panel is fully open. Plain numbers rather than a
    /// CGSize: this file imports only Foundation, where CGSize is not Equatable.
    var bodyWidth: CGFloat
    var bodyHeight: CGFloat
    /// Horizontal distance from the moving panel's left edge to where the body's
    /// left edge will rest.
    var bodyShift: CGFloat
}
struct ProviderState: Codable, Equatable { let id: String; var health: String }
struct LiveSnapshot: Codable {
    let type: String
    let version: Int
    let generatedAt: Double
    let providers: [ProviderState]
    let tasks: [LiveTask]
}
struct ReviewItem: Codable, Identifiable, Equatable {
    let id: String
    var task: LiveTask
    let queuedAt: Double
}
/// One visible review task can retain several independently identified results.
/// Capture this value at click time so later results cannot be acknowledged.
struct ReviewGroup: Identifiable, Equatable {
    let id: String
    let task: LiveTask
    let items: [ReviewItem]
}
private struct ReviewLedger: Codable {
    var version = 1
    var seenSessions: Set<String> = []
    var knownResults: Set<String> = []
    var reviewed: Set<String> = []
    var pending: [ReviewItem] = []
    // Optional so records written by earlier versions still load, and so an
    // earlier version can still load this file after a rollback.
    /// Sessions whose turn record has been baselined.
    var trackedSessions: Set<String>? = nil
    /// Cached rows last seen active: session identity -> original observation time.
    var activeObservations: [String: Double]? = nil
    /// Endings inferred from an observed change of a cached row.
    var observedPending: [ReviewItem]? = nil
}

/// The source owns runtime/read state; this local ledger owns explicit review.
@MainActor
final class LiveModel: ObservableObject {
    @Published var expanded = false
    @Published var selection: TaskSection = .review {
        didSet { if selection != oldValue { cancelNavigation() } }
    }
    /// Where the summary tabs are laid out, in the view's global (top-left) coordinates.
    /// Written by the view on layout and read on pointer movement for hover selection.
    /// Deliberately not published: it changes every frame while the panel moves.
    var tabFrames: [TaskSection: CGRect] = [:]
    @Published var safeTop: CGFloat = 0
    /// Width of the camera housing while docked as an island beside it; 0 when floating.
    @Published var notchWidth: CGFloat = 0
    /// While docked: from the panel's left edge to the housing's, taken from the real
    /// frame, so the ears stay beside the housing while the panel moves.
    @Published var notchLeading: CGFloat = 0
    var isIsland: Bool { safeTop > 0 && notchWidth > 0 }
    /// Set only while the panel frame is moving. Nil at rest, when `expanded` alone
    /// says whether the panel is open.
    @Published var revealMotion: RevealMotion? = nil
    /// How far the panel is open: 0 compact, 1 expanded.
    var reveal: Double { min(1, max(0, revealMotion?.progress ?? (expanded ? 1 : 0))) }
    @Published private(set) var tasks: [LiveTask] = []
    @Published private(set) var providers: [ProviderState] = []
    @Published private(set) var pendingResults: [ReviewItem] = []
    @Published private(set) var ledgerError: String?
    @Published private(set) var isStale = true
    @Published private(set) var nowMs = LiveModel.milliseconds()
    @Published private(set) var navigationFeedback: String?
    @Published private(set) var reviewFeedback: String?
    var onAttentionEvent: ((AttentionEvent) -> Void)?
    private(set) var navigationAttemptCount = 0
    private(set) var navigationSuccessCount = 0
    private var lastNavigationTaskID: String?
    private var navigationGeneration = 0
    private var ledger = ReviewLedger()
    private let ledgerURL: URL
    private let persist: Bool
    private var lastGeneratedAt: Double?
    private var explicitlyDisconnected = false
    private var selectedResultID: String?
    // Process-local baselines keep restored history quiet without silencing new
    // turns after a bridge reconnect. Unknown states never resolve input episodes.
    private var attentionSessions: Set<String> = []
    private var attentionStates: [String: (state: LiveState, observedAt: Double)] = [:]

    init(stateDirectory: URL, persist: Bool = true) {
        self.persist = persist
        ledgerURL = stateDirectory.appendingPathComponent("review-ledger.json")
        if persist {
            do {
                try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
                if FileManager.default.fileExists(atPath: ledgerURL.path) {
                    let value = try JSONDecoder().decode(ReviewLedger.self, from: Data(contentsOf: ledgerURL))
                    let stored = value.pending + (value.observedPending ?? [])
                    guard value.version == 1, stored.count <= 100_000,
                          Set(stored.map(\.id)).count == stored.count,
                          stored.allSatisfy({ Self.resultIdentity($0.task) == $0.id && Self.validTask($0.task) }),
                          value.pending.allSatisfy({ $0.task.completionTracking != Self.observedChange }),
                          (value.observedPending ?? []).allSatisfy({ $0.task.completionTracking == Self.observedChange }),
                          (value.activeObservations ?? [:]).count <= 100_000,
                          (value.activeObservations ?? [:]).values.allSatisfy({ $0.isFinite && $0 > 0 })
                    else { throw CocoaError(.fileReadCorruptFile) }
                    ledger = value
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
                }
            } catch {
                ledgerError = "Cannot read review history. The original file is unchanged. Fix it before retrying."
            }
        }
        rebuildPending()
    }

    nonisolated static func milliseconds() -> Double { Date().timeIntervalSince1970 * 1000 }
    private static func scope(_ parts: [String]) -> String {
        // JSON arrays avoid delimiter collisions in arbitrary session/result identities.
        (try? JSONEncoder().encode(parts).base64EncodedString()) ?? ""
    }
    private static func sessionIdentity(_ task: LiveTask) -> String { scope([task.provider, task.id]) }
    static let turnRecord = "turn-record"
    static let observedChange = "observed-change"
    private static let observedKeyPrefix = "result:observed-end:"
    private static func resultIdentity(_ task: LiveTask) -> String? {
        // Cached activity has no source completion/read receipt. The only identity
        // a cached row can carry is one minted here from an observed state change.
        if task.observationSource == "claude-cache" && task.completionTracking != observedChange { return nil }
        guard let key = task.resultKey, !key.isEmpty else { return nil }
        return scope([task.provider, task.id, key])
    }
    private static func validTask(_ task: LiveTask) -> Bool {
        ["codex", "claude"].contains(task.provider) && !task.id.isEmpty && task.id.count <= 1024 &&
        task.title.count <= 500 && (task.resultKey?.count ?? 0) <= 2048 && validResultKey(task.resultKey) &&
        (task.sourceURL?.count ?? 0) <= 4096 &&
        ["live", "history", "unavailable"].contains(task.evidence) &&
        task.observedAt.isFinite && task.updatedAt.isFinite && validDestination(task) &&
        (task.lastObservedState == nil || (task.provider == "claude" && task.observationSource == "claude-cache" && [.running, .input, .idle].contains(task.lastObservedState!))) &&
        (task.availabilityReason == nil || ["catalog-only", "source-offline", "runtime-unavailable", "stale-cache", "remote-disconnected", "metadata-only", "turn-record-only"].contains(task.availabilityReason!)) &&
        (task.completionTracking == nil ||
            (task.completionTracking == turnRecord && task.provider == "claude" && task.observationSource == nil) ||
            (task.completionTracking == observedChange && task.provider == "claude" && task.observationSource == "claude-cache" &&
                task.state == .idle && (task.resultKey?.hasPrefix(observedKeyPrefix) ?? false))) &&
        (task.observationSource == nil || (task.observationSource == "claude-cache" && task.provider == "claude" &&
            [.running, .input, .idle, .error, .unknown].contains(task.state)))
    }
    private static func validResultKey(_ key: String?) -> Bool {
        guard let key else { return true }
        return (key.hasPrefix("result:") && key.count > 7) || (key.hasPrefix("error:") && key.count > 6)
    }
    private static func validDestination(_ task: LiveTask) -> Bool {
        guard let text = task.sourceURL else { return true }
        guard let url = validatedSourceURL(text), let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        if task.provider == "codex" {
            return c.scheme == "codex" && c.host == "threads" && task.id == "codex:" + String(c.path.dropFirst())
        }
        guard task.provider == "claude", c.scheme == "claude", c.host == "code" else { return false }
        let session = c.path == "/continue" ? c.queryItems?.first?.value : String(c.path.dropFirst())
        return session.map { task.id == "claude:" + $0 } ?? false
    }
    static func validatedSourceURL(_ value: String?) -> URL? {
        guard let value, value.count <= 4096, value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let c = URLComponents(string: value), c.user == nil, c.password == nil,
              c.port == nil, c.fragment == nil, c.percentEncodedPath == c.path else { return nil }
        if c.scheme == "codex", c.host == "threads",
           c.path.range(of: "^/[A-Za-z0-9][A-Za-z0-9_-]{5,127}$", options: .regularExpression) != nil {
            if c.query == nil { return c.url }
            if let items = c.queryItems, items.count == 1, items[0].name == "hostId",
               let host = items[0].value,
               host.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", options: .regularExpression) != nil { return c.url }
            return nil
        }
        if c.scheme == "claude", c.host == "code", c.path == "/continue",
           let items = c.queryItems, items.count == 1, items[0].name == "session",
           let session = items[0].value,
           session.range(of: "^local_[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil {
            return c.url
        }
        if c.scheme == "claude", c.host == "code", c.query == nil,
           c.path.range(of: "^/(cse|session)_[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil { return c.url }
        return nil
    }

    var connectionLabel: String {
        guard !explicitlyDisconnected else { return "Offline" }
        guard lastGeneratedAt != nil else { return "Connecting" }
        guard !isStale else { return "Offline" }
        guard providers.contains(where: { ["live", "degraded"].contains($0.health) }) else { return "Offline" }
        return tasks.contains(where: { displayState($0) == .unknown }) ? "Partial" : "Local"
    }
    /// Sessions confirmed running right now. A stale "last seen running" row is not one.
    private var runningSessions: Set<String> {
        Set(tasks.filter { displayState($0) == .running }.map { Self.sessionIdentity($0) })
    }
    /// Pending results shown in Review. A session that is running again keeps its
    /// queued results in the ledger, unacknowledged, but they stay out of Review
    /// until it stops, so one task is never listed under both Running and Review.
    var visiblePendingResults: [ReviewItem] {
        let running = runningSessions
        return running.isEmpty ? pendingResults : pendingResults.filter { !running.contains(Self.sessionIdentity($0.task)) }
    }
    var currentResult: ReviewItem? {
        let visible = visiblePendingResults
        if let selectedResultID, let item = visible.first(where: { $0.id == selectedResultID }) { return item }
        return visible.first
    }
    var pendingReviewGroups: [ReviewGroup] { groupedReviews(visiblePendingResults) }
    var currentReviewGroup: ReviewGroup? {
        if let selectedResultID, let group = pendingReviewGroups.first(where: { $0.items.contains(where: { $0.id == selectedResultID }) }) {
            return group
        }
        return pendingReviewGroups.first
    }
    func tasks(for provider: TaskProvider) -> [LiveTask] {
        tasks.filter { $0.provider == provider.rawValue }
    }
    func reviewGroups(for provider: TaskProvider) -> [ReviewGroup] {
        groupedReviews(visiblePendingResults.filter { $0.task.provider == provider.rawValue })
    }
    private func groupedReviews(_ items: [ReviewItem]) -> [ReviewGroup] {
        var order: [String] = []
        var values: [String: [ReviewItem]] = [:]
        for item in items {
            let key = Self.sessionIdentity(item.task)
            if values[key] == nil { order.append(key) }
            values[key, default: []].append(item)
        }
        return order.compactMap { key in
            guard let rows = values[key], let latest = rows.last else { return nil }
            return ReviewGroup(id: key, task: latest.task, items: rows)
        }
    }
    func displayState(_ task: LiveTask) -> LiveState {
        guard !isStale, !explicitlyDisconnected, task.evidence == "live",
              providers.contains(where: { $0.id == task.provider && ["live", "degraded"].contains($0.health) })
        else { return .unknown }
        if cacheObservationExpired(task) { return .unknown }
        return task.state
    }
    func observationAgeSeconds(_ task: LiveTask) -> Int {
        let age = nowMs - task.observedAt
        guard task.observedAt > 0, age.isFinite, age >= 0 else { return -1 }
        return Int(min(age / 1_000, Double(Int.max - 1)))
    }
    func cacheObservationExpired(_ task: LiveTask) -> Bool {
        guard task.observationSource == "claude-cache" else { return false }
        let age = nowMs - task.observedAt
        return task.observedAt <= 0 || !age.isFinite || age < 0 || age > 20_000
    }
    var recentActivity: [LiveTask] {
        tasks.filter { displayState($0) == .unknown && $0.observationSource == "claude-cache" &&
            ($0.lastObservedState == .running || $0.lastObservedState == .input) && $0.observedAt > 0 && $0.observedAt <= nowMs }
            .sorted { $0.observedAt > $1.observedAt }
    }
    var claudeStatusDelayed: Bool { !recentActivity.isEmpty }
    /// Tasks whose last observation said running and has since gone stale. They are
    /// never counted as running; the compact bar shows them as unconfirmed so a task
    /// the source list has not refreshed does not read as "nothing is running". An
    /// observation older than two hours says too little to show.
    var unconfirmedRunningCount: Int {
        recentActivity.filter { $0.lastObservedState == .running && nowMs - $0.observedAt <= 7_200_000 }.count
    }
    var claudeCoverageIncomplete: Bool {
        providers.first(where: { $0.id == "claude" })?.health != "live" || tasks.contains { $0.provider == "claude" && displayState($0) == .unknown }
    }
    var preferredPanelHeight: CGFloat {
        let count: Int
        switch selection {
        case .review: count = pendingReviewGroups.count
        case .running: count = self.count(.running) + recentActivity.count
        case .input: count = self.count(.input)
        case .all: count = tasks.filter { displayState($0) != .unknown }.count + recentActivity.count
        }
        return CGFloat(86 + min(3, max(1, count)) * 62)
    }
    func isHistorical(_ item: ReviewItem) -> Bool {
        guard !isStale, let current = tasks.first(where: { $0.id == item.task.id && $0.provider == item.task.provider }),
              displayState(current) != .unknown, current.resultKey == item.task.resultKey else { return true }
        return false
    }
    func count(_ section: TaskSection) -> Int {
        switch section {
        case .running: return tasks.filter { displayState($0) == .running }.count
        case .input: return tasks.filter { displayState($0) == .input }.count
        case .review: return pendingReviewGroups.count
        case .all: return tasks.count
        }
    }
    func count(_ section: TaskSection, provider: TaskProvider) -> Int {
        switch section {
        case .running: return tasks(for: provider).filter { displayState($0) == .running }.count
        case .input: return tasks(for: provider).filter { displayState($0) == .input }.count
        case .review: return reviewGroups(for: provider).count
        case .all: return tasks(for: provider).count
        }
    }
    func canMarkReviewed(_ item: ReviewItem) -> Bool {
        ledgerError == nil && Self.resultIdentity(item.task) == item.id && storedPending.contains { $0.id == item.id }
    }
    func isResultReviewed(_ task: LiveTask) -> Bool {
        guard let identity = Self.resultIdentity(task) else { return false }
        return ledger.reviewed.contains(identity)
    }
    func canMarkReviewed(_ group: ReviewGroup) -> Bool {
        guard !group.items.isEmpty, Self.sessionIdentity(group.task) == group.id,
              Set(group.items.map(\.id)).count == group.items.count else { return false }
        return group.items.allSatisfy {
            Self.sessionIdentity($0.task) == group.id && canMarkReviewed($0)
        }
    }
    /// An Open is in flight; hover must not change the selection under it.
    private(set) var navigationPending = false
    @discardableResult func beginNavigation(_ task: LiveTask) -> Int {
        navigationGeneration += 1
        navigationPending = true
        navigationAttemptCount += 1
        lastNavigationTaskID = task.id
        navigationFeedback = "Opening original task..."
        return navigationGeneration
    }
    @discardableResult func finishNavigation(success: Bool, synthetic: Bool = false, generation: Int) -> Bool {
        guard generation == navigationGeneration else { return false }
        navigationPending = false
        if success { navigationSuccessCount += 1 }
        navigationFeedback = synthetic ? "Test: correct task found. No real session opened." : success
            ? "Original task opened. Review history is unchanged." : "Cannot open the original task. Copy its title and search in the source app."
        return true
    }
    private func cancelNavigation() {
        navigationGeneration += 1
        navigationPending = false
        navigationFeedback = nil
    }

    func apply(_ snapshot: LiveSnapshot, nowMs: Double = LiveModel.milliseconds()) {
        self.nowMs = nowMs
        guard snapshot.type == "snapshot", snapshot.version == 1, snapshot.generatedAt.isFinite,
              abs(nowMs - snapshot.generatedAt) <= 5_000, snapshot.tasks.count <= 20_000,
              snapshot.providers.count <= 2, Set(snapshot.providers.map(\.id)).count == snapshot.providers.count,
              snapshot.providers.allSatisfy({ ["codex", "claude"].contains($0.id) &&
                  ["connecting", "live", "degraded", "offline"].contains($0.health) }),
              snapshot.tasks.allSatisfy(Self.validTask),
              // Inferred endings are minted from this app's own observations only.
              snapshot.tasks.allSatisfy({ $0.completionTracking != Self.observedChange }),
              Set(snapshot.tasks.map { Self.sessionIdentity($0) }).count == snapshot.tasks.count
        else { disconnected(); return }
        if let previous = lastGeneratedAt, snapshot.generatedAt < previous { return }
        tasks = snapshot.tasks.map { task in
            var safe = task
            safe.sourceURL = Self.validatedSourceURL(task.sourceURL)?.absoluteString
            return safe
        }
        providers = snapshot.providers
        lastGeneratedAt = snapshot.generatedAt
        explicitlyDisconnected = false
        isStale = false
        let previousLedger = ledger
        for task in tasks {
            let sessionID = Self.sessionIdentity(task)
            if task.observationSource == "claude-cache" {
                noteCacheObservation(task, sessionID: sessionID, queuedAt: snapshot.generatedAt)
                continue
            }
            // Runtime state needs current evidence. A turn record does not: it names
            // the last finished turn even when nothing says what the task is doing.
            let tracked = task.completionTracking == Self.turnRecord
            let state = displayState(task)
            guard state != .unknown || tracked else { continue }
            let firstMeaningfulObservation = tracked
                ? !(ledger.trackedSessions ?? []).contains(sessionID)
                : !ledger.seenSessions.contains(sessionID)
            if tracked {
                // The record carries its own counter, so the first sight of it is a
                // complete baseline, and an absent key means no turn has finished.
                var sessions = ledger.trackedSessions ?? []
                if sessions.insert(sessionID).inserted { ledger.trackedSessions = sessions }
                ledger.seenSessions.insert(sessionID)
            } else if task.state != .read || Self.resultIdentity(task) != nil {
                // Catalog-only unknowns and read results without an identity do not
                // turn first real snapshots into a spurious completion backlog.
                ledger.seenSessions.insert(sessionID)
            }
            guard tracked || [.review, .read, .error].contains(state), let resultID = Self.resultIdentity(task) else { continue }
            let unseenResult = !ledger.knownResults.contains(resultID)
            ledger.knownResults.insert(resultID)
            let shouldQueue = state == .review || state == .error ||
                (unseenResult && !firstMeaningfulObservation)
            if shouldQueue && !ledger.reviewed.contains(resultID) && !ledger.pending.contains(where: { $0.id == resultID }) {
                ledger.pending.append(ReviewItem(id: resultID, task: Self.storable(task), queuedAt: snapshot.generatedAt))
            }
            if let index = ledger.pending.firstIndex(where: { $0.id == resultID }) {
                // Preserve the completion identity while keeping its navigation metadata current.
                // Observation times move on every snapshot; they alone are not worth a disk write.
                let latest = Self.storable(task)
                if !Self.sameApartFromTimes(ledger.pending[index].task, latest) { ledger.pending[index].task = latest }
            }
        }
        if var active = ledger.activeObservations {
            // Rows that left the source list would otherwise be remembered forever.
            let cutoff = nowMs - 30 * 86_400_000
            active = active.filter { $0.value >= cutoff }
            ledger.activeObservations = active.isEmpty ? nil : active
        }
        let saved = Self.equalLedger(previousLedger, ledger) || saveLedger()
        rebuildPending()
        guard saved, ledgerError == nil else { return }
        emitAttentionEvents(previousLedger: previousLedger)
    }

    private func attentionSourceAvailable(_ task: LiveTask) -> Bool {
        providers.contains(where: { $0.id == task.provider && ["live", "degraded"].contains($0.health) }) &&
            !["source-offline", "remote-disconnected"].contains(task.availabilityReason ?? "")
    }

    private func canObserveAttentionCompletion(_ task: LiveTask) -> Bool {
        guard attentionSourceAvailable(task) else { return false }
        return displayState(task) != .unknown ||
            (task.completionTracking == Self.turnRecord && task.availabilityReason == "turn-record-only")
    }

    private func emitAttentionEvents(previousLedger: ReviewLedger) {
        let previousIDs = Set((previousLedger.pending + (previousLedger.observedPending ?? [])).map(\.id))
        let newItems = storedPending.filter {
            !previousIDs.contains($0.id) && !previousLedger.knownResults.contains($0.id)
        }
        let newSessions = Set(newItems.map { Self.sessionIdentity($0.task) })
        // A newly inferred ending is a fact about two original observations,
        // even when TTL now makes both unsuitable for current runtime display.
        let inferredSessions = Set(newItems.compactMap { item -> String? in
            let sessionID = Self.sessionIdentity(item.task)
            guard item.task.completionTracking == Self.observedChange,
                  let activeAt = previousLedger.activeObservations?[sessionID], item.task.observedAt > activeAt
            else { return nil }
            return sessionID
        })
        var completed = false
        var input = false
        for task in tasks {
            let sessionID = Self.sessionIdentity(task)
            guard attentionSourceAvailable(task) else { continue }
            if canObserveAttentionCompletion(task) || (task.evidence != "unavailable" && inferredSessions.contains(sessionID)) {
                if attentionSessions.contains(sessionID) && newSessions.contains(sessionID) { completed = true }
                attentionSessions.insert(sessionID)
            }
            let state = displayState(task)
            guard state != .unknown else { continue }
            if let previous = attentionStates[sessionID] {
                // A replayed cache row cannot resolve an episode or create another
                // input edge. Non-cache sources can change state at equal times.
                guard task.observedAt >= previous.observedAt,
                      task.observationSource != "claude-cache" || task.observedAt > previous.observedAt
                else { continue }
                if state == .input && previous.state != .input { input = true }
            }
            attentionStates[sessionID] = (state, task.observedAt)
        }
        if completed { onAttentionEvent?(.completed) }
        if input { onAttentionEvent?(.input) }
    }

    private static func sameApartFromTimes(_ a: LiveTask, _ b: LiveTask) -> Bool {
        a.id == b.id && a.provider == b.provider && a.title == b.title && a.state == b.state &&
        a.resultKey == b.resultKey && a.sourceURL == b.sourceURL && a.evidence == b.evidence &&
        a.observationSource == b.observationSource && a.availabilityReason == b.availabilityReason &&
        a.lastObservedState == b.lastObservedState && a.completionTracking == b.completionTracking
    }
    /// Stored copies stay readable by earlier versions, which reject newer reasons.
    private static func storable(_ task: LiveTask) -> LiveTask {
        var copy = task
        if copy.availabilityReason == "turn-record-only" { copy.availabilityReason = nil }
        return copy
    }
    /// A cached row is a timestamped fact about the past, even after it is too old
    /// to describe the present. Active at one observation and idle at a later one
    /// means the work ended in between. That is an inference: it has no source turn
    /// identity and cannot tell success from an interruption, so it is labelled.
    private func noteCacheObservation(_ task: LiveTask, sessionID: String, queuedAt: Double) {
        let current = displayState(task)
        if [.running, .input].contains(current) { ledger.seenSessions.insert(sessionID) }
        for index in (ledger.observedPending ?? []).indices where ledger.observedPending![index].task.id == task.id {
            ledger.observedPending![index].task.title = task.title
            ledger.observedPending![index].task.sourceURL = task.sourceURL
        }
        let at = task.observedAt
        guard let observed = task.lastObservedState ?? (current == .unknown ? nil : current),
              at.isFinite, at > 0, at <= nowMs + 1_000 else { return }
        var active = ledger.activeObservations ?? [:]
        if observed == .running || observed == .input {
            if at > (active[sessionID] ?? 0) { active[sessionID] = at; ledger.activeObservations = active }
            return
        }
        guard observed == .idle, let activeAt = active[sessionID], at > activeAt else { return }
        active.removeValue(forKey: sessionID)
        ledger.activeObservations = active.isEmpty ? nil : active
        let ended = LiveTask(id: task.id, provider: task.provider, title: task.title, state: .idle,
            resultKey: Self.observedKeyPrefix + String(Int64(activeAt)), sourceURL: task.sourceURL,
            observedAt: at, evidence: "history", updatedAt: at, observationSource: "claude-cache",
            availabilityReason: nil, lastObservedState: .idle, completionTracking: Self.observedChange)
        guard let resultID = Self.resultIdentity(ended), ledger.knownResults.insert(resultID).inserted,
              !ledger.reviewed.contains(resultID) else { return }
        ledger.observedPending = (ledger.observedPending ?? []) + [ReviewItem(id: resultID, task: ended, queuedAt: queuedAt)]
    }
    private var storedPending: [ReviewItem] {
        guard let observed = ledger.observedPending, !observed.isEmpty else { return ledger.pending }
        return (ledger.pending + observed).enumerated()
            .sorted { $0.element.queuedAt != $1.element.queuedAt ? $0.element.queuedAt < $1.element.queuedAt : $0.offset < $1.offset }
            .map(\.element)
    }
    private func removePending(_ ids: Set<String>) {
        ledger.pending.removeAll { ids.contains($0.id) }
        if var observed = ledger.observedPending {
            observed.removeAll { ids.contains($0.id) }
            ledger.observedPending = observed.isEmpty ? nil : observed
        }
    }

    func tick(nowMs: Double = LiveModel.milliseconds()) {
        self.nowMs = nowMs
        let stale = explicitlyDisconnected || lastGeneratedAt.map { nowMs - $0 > 5_000 || $0 - nowMs > 5_000 } ?? true
        if stale != isStale { isStale = stale }
        rebuildPending()
    }
    func disconnected() {
        explicitlyDisconnected = true
        isStale = true
        providers = providers.map { ProviderState(id: $0.id, health: "offline") }
        rebuildPending()
    }
    func skip() {
        let visible = visiblePendingResults
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex(where: { $0.id == currentResult?.id }) ?? 0
        selectReview(visible[(index + 1) % visible.count].id)
    }
    func selectReview(_ id: String) {
        guard visiblePendingResults.contains(where: { $0.id == id }) else { return }
        selectedResultID = id
        cancelNavigation()
        objectWillChange.send()
    }
    func selectReviewGroup(_ group: ReviewGroup) {
        guard let current = pendingReviewGroups.first(where: { $0.id == group.id }),
              let latest = current.items.last else { return }
        selectReview(latest.id)
    }
    func skipReviewGroup() {
        let groups = pendingReviewGroups
        guard !groups.isEmpty else { return }
        let index = groups.firstIndex(where: { $0.id == currentReviewGroup?.id }) ?? 0
        selectReviewGroup(groups[(index + 1) % groups.count])
    }
    func markReviewed() { if let item = currentResult { markReviewed(item) } }
    func markReviewed(_ item: ReviewItem) {
        guard canMarkReviewed(item) else { return }
        cancelNavigation()
        let previous = ledger
        ledger.reviewed.insert(item.id)
        removePending([item.id])
        if !saveLedger() { ledger = previous }
        rebuildPending()
    }
    func markReviewed(_ group: ReviewGroup) {
        guard canMarkReviewed(group) else { return }
        cancelNavigation()
        let previous = ledger
        let capturedIDs = Set(group.items.map(\.id))
        ledger.reviewed.formUnion(capturedIDs)
        removePending(capturedIDs)
        let saved = saveLedger()
        if !saved { ledger = previous }
        rebuildPending()
        if saved {
            let confirmed = "Confirmed \(capturedIDs.count) update\(capturedIDs.count == 1 ? "" : "s")."
            reviewFeedback = pendingReviewGroups.contains(where: { $0.id == group.id })
                ? confirmed + " New results still need review."
                : confirmed + " Counts are up to date."
        }
    }
    private func rebuildPending() {
        var items = storedPending
        for task in tasks where [.review, .error].contains(displayState(task)) && Self.resultIdentity(task) == nil {
            items.append(ReviewItem(id: "unconfirmed:" + Self.sessionIdentity(task), task: task,
                                    queuedAt: lastGeneratedAt ?? 0))
        }
        pendingResults = items
        if !items.contains(where: { $0.id == selectedResultID }) { selectedResultID = items.first?.id }
    }
    private static func equalLedger(_ a: ReviewLedger, _ b: ReviewLedger) -> Bool {
        a.seenSessions == b.seenSessions && a.knownResults == b.knownResults && a.reviewed == b.reviewed && a.pending == b.pending &&
        a.trackedSessions == b.trackedSessions && a.activeObservations == b.activeObservations && a.observedPending == b.observedPending
    }
    @discardableResult private func saveLedger() -> Bool {
        guard persist else { return true }
        guard ledgerError == nil else { return false }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let temporary = ledgerURL.deletingLastPathComponent().appendingPathComponent(".review-ledger-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try encoder.encode(ledger).write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: ledgerURL.path) {
                _ = try FileManager.default.replaceItemAt(ledgerURL, withItemAt: temporary, options: .usingNewMetadataOnly)
            } else {
                try FileManager.default.moveItem(at: temporary, to: ledgerURL)
            }
            return true
        } catch {
            ledgerError = "Cannot save review history. The original file is unchanged. Review confirmation is unavailable."
            return false
        }
    }
    func diagnostics() -> [String: Any] {
        ["taskCount": tasks.count, "liveCount": tasks.filter { displayState($0) != .unknown }.count,
         "runningCount": count(.running), "inputCount": count(.input), "pendingCount": pendingResults.count,
         "pendingTaskCount": pendingReviewGroups.count,
         "unknownCount": tasks.filter { displayState($0) == .unknown }.count,
         "knownCompletionCount": ledger.knownResults.count, "reviewedCount": ledger.reviewed.count,
         "recentActivityCount": recentActivity.count, "claudeStatusDelayed": claudeStatusDelayed,
         "turnRecordTaskCount": tasks.filter { $0.completionTracking == Self.turnRecord }.count,
         "turnRecordBaselineCount": ledger.trackedSessions?.count ?? 0,
         "inferredPendingCount": ledger.observedPending?.count ?? 0,
         "navigationAttemptCount": navigationAttemptCount, "navigationSuccessCount": navigationSuccessCount,
         "lastNavigationMatchesCurrentReview": lastNavigationTaskID != nil && lastNavigationTaskID == currentResult?.task.id,
         "isStale": isStale, "ledgerError": ledgerError != nil,
         "providerHealth": Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.health) })]
    }
}

@MainActor
func runModelSelfChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("task-island-ledger-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = LiveModel.milliseconds()
    func task(_ id: String = "codex:sample-a", _ state: LiveState = .read, _ result: String? = "result:turn-1",
              evidence: String = "live") -> LiveTask {
        LiveTask(id: id, provider: "codex", title: "Synthetic task", state: state, resultKey: result,
                 sourceURL: "codex://threads/" + String(id.dropFirst("codex:".count)), observedAt: now, evidence: evidence, updatedAt: now)
    }
    func snapshot(_ tasks: [LiveTask], at: Double = now) -> LiveSnapshot {
        LiveSnapshot(type: "snapshot", version: 1, generatedAt: at,
                     providers: [ProviderState(id: "codex", health: "live")], tasks: tasks)
    }
    let model = LiveModel(stateDirectory: directory)
    model.apply(snapshot([task("codex:sample-a", .unknown, nil, evidence: "unavailable")]), nowMs: now)
    model.apply(snapshot([task()]), nowMs: now)
    assert(model.count(.review) == 0, "Initial source-read after catalog discovery establishes a baseline")
    model.apply(snapshot([task("codex:sample-a", .review, "result:turn-1")]), nowMs: now)
    assert(model.count(.review) == 1)
    let old = model.currentResult!
    model.apply(snapshot([task()]), nowMs: now)
    assert(model.count(.review) == 1, "Source-read never acknowledges a local pending result")
    model.apply(snapshot([task("codex:sample-a", .read, "result:turn-2")]), nowMs: now)
    assert(model.count(.review) == 1 && model.pendingResults.count == 2,
           "Each task is counted once while both completion identities stay queued")
    let oldLedgerData = try Data(contentsOf: directory.appendingPathComponent("review-ledger.json"))
    let oldLedgerJSON = try JSONSerialization.jsonObject(with: oldLedgerData) as! [String: Any]
    let oldTaskJSON = (oldLedgerJSON["pending"] as! [[String: Any]])[0]["task"] as! [String: Any]
    assert(oldTaskJSON["observationSource"] == nil, "Older task records omit the optional cache tag")
    model.skip(); assert(model.currentResult?.id != old.id && model.count(.review) == 1 && model.pendingResults.count == 2)
    model.markReviewed(old)
    assert(model.count(.review) == 1 && model.currentResult?.task.resultKey == "result:turn-2")
    let reloaded = LiveModel(stateDirectory: directory)
    assert(reloaded.count(.review) == 1 && reloaded.isHistorical(reloaded.currentResult!))
    reloaded.apply(snapshot([task("codex:sample-a", .read, "result:turn-2")]), nowMs: now)
    assert(reloaded.count(.review) == 1)
    reloaded.markReviewed()
    reloaded.apply(snapshot([task("codex:sample-a", .review, "result:turn-1")]), nowMs: now)
    assert(reloaded.count(.review) == 0, "Old identities do not requeue after explicit review")
    reloaded.apply(snapshot([task("codex:sample-a", .running, nil)]), nowMs: now)
    assert(reloaded.count(.running) == 1)
    reloaded.tick(nowMs: now + 5_001)
    assert(reloaded.count(.running) == 0 && reloaded.isStale)
    reloaded.apply(snapshot([task("codex:sample-a", .review, nil)], at: now + 6_000), nowMs: now + 6_000)
    assert(reloaded.count(.review) == 1 && !reloaded.canMarkReviewed(reloaded.currentResult!))
    reloaded.markReviewed(); assert(reloaded.count(.review) == 1)
    reloaded.disconnected(); assert(reloaded.count(.review) == 0 && reloaded.connectionLabel == "Offline")
    assert(LiveModel.validatedSourceURL("https://example.com") == nil)
    assert(LiveModel.validatedSourceURL("codex://threads/sample-a?unexpected=1") == nil)
    assert(LiveModel.validatedSourceURL("claude://code/continue?session=local_demo") != nil)
    let malformed = LiveModel(stateDirectory: directory, persist: false)
    malformed.apply(snapshot([task("codex:sample-a", .review, "request:not-a-completion")]), nowMs: now)
    assert(malformed.isStale && malformed.count(.review) == 0)
    func cache(_ state: LiveState, observed: Double, key: String? = nil) -> LiveTask {
        LiveTask(id: "claude:session_cache_demo", provider: "claude", title: "Synthetic cached activity", state: state,
                 resultKey: key, sourceURL: "claude://code/session_cache_demo", observedAt: observed,
                 evidence: "live", updatedAt: observed, observationSource: "claude-cache")
    }
    func cacheSnapshot(_ task: LiveTask, at: Double) -> LiveSnapshot {
        LiveSnapshot(type: "snapshot", version: 1, generatedAt: at,
                     providers: [ProviderState(id: "claude", health: "live")], tasks: [task])
    }
    let tagged = cache(.running, observed: now)
    let taggedData = try JSONEncoder().encode(tagged)
    let decodedTagged = try JSONDecoder().decode(LiveTask.self, from: taggedData)
    assert(decodedTagged.observationSource == "claude-cache")
    var oldJSON = try JSONSerialization.jsonObject(with: taggedData) as! [String: Any]
    oldJSON.removeValue(forKey: "observationSource")
    let untagged = try JSONDecoder().decode(LiveTask.self, from: JSONSerialization.data(withJSONObject: oldJSON))
    assert(untagged.observationSource == nil)
    let cachedModel = LiveModel(stateDirectory: directory, persist: false)
    cachedModel.apply(cacheSnapshot(tagged, at: now), nowMs: now)
    assert(cachedModel.count(.running) == 1)
    cachedModel.apply(cacheSnapshot(tagged, at: now + 19_000), nowMs: now + 19_000)
    assert(cachedModel.count(.running) == 1 && cachedModel.observationAgeSeconds(tagged) == 19)
    var clockNotifications = 0
    let clockSubscription = cachedModel.$nowMs.sink { _ in clockNotifications += 1 }
    cachedModel.tick(nowMs: now + 20_001)
    assert(!cachedModel.isStale && cachedModel.count(.running) == 0 && cachedModel.cacheObservationExpired(tagged))
    assert(clockNotifications >= 2, "Time updates publish even while the bridge heartbeat remains fresh")
    withExtendedLifetime(clockSubscription) {}
    cachedModel.apply(cacheSnapshot(tagged, at: now + 21_000), nowMs: now + 21_000)
    assert(cachedModel.count(.running) == 0, "Fresh heartbeats cannot refresh old cache observations")
    let future = cache(.running, observed: now + 30_000)
    cachedModel.apply(cacheSnapshot(future, at: now + 22_000), nowMs: now + 22_000)
    assert(cachedModel.count(.running) == 0 && cachedModel.observationAgeSeconds(future) == -1)
    let cacheIdle = cache(.idle, observed: now + 25_000, key: "result:not-an-authoritative-receipt")
    cachedModel.apply(cacheSnapshot(cacheIdle, at: now + 25_000), nowMs: now + 25_000)
    assert(cachedModel.displayState(cacheIdle) == .idle && cachedModel.count(.review) == 1,
           "Active at one observation and idle at a later one is one inferred ending")
    let inferred = cachedModel.currentResult!
    assert(inferred.task.completionTracking == LiveModel.observedChange &&
           inferred.task.resultKey == "result:observed-end:" + String(Int64(now)),
           "The inferred identity is local and never the key a cached row supplied")
    assert(cachedModel.canMarkReviewed(inferred) && cachedModel.diagnostics()["knownCompletionCount"] as? Int == 1)
    cachedModel.apply(cacheSnapshot(cache(.idle, observed: now + 26_000), at: now + 26_000), nowMs: now + 26_000)
    assert(cachedModel.pendingResults.count == 1, "Repeated idle observations are the same ending")
    cachedModel.markReviewed(inferred)
    cachedModel.apply(cacheSnapshot(cache(.idle, observed: now + 27_000), at: now + 27_000), nowMs: now + 27_000)
    assert(cachedModel.count(.review) == 0, "A confirmed inferred ending does not return")
    cachedModel.apply(cacheSnapshot(cache(.running, observed: now + 28_000), at: now + 28_000), nowMs: now + 28_000)
    cachedModel.apply(cacheSnapshot(cache(.idle, observed: now + 29_000), at: now + 29_000), nowMs: now + 29_000)
    assert(cachedModel.count(.review) == 1 && cachedModel.currentResult?.id != inferred.id, "A later run ends separately")
    let claimed = LiveTask(id: tagged.id, provider: "claude", title: tagged.title, state: .idle,
        resultKey: "result:observed-end:1", sourceURL: tagged.sourceURL, observedAt: now + 30_000, evidence: "live",
        updatedAt: now + 30_000, observationSource: "claude-cache", completionTracking: LiveModel.observedChange)
    let claimedModel = LiveModel(stateDirectory: directory, persist: false)
    claimedModel.apply(cacheSnapshot(claimed, at: now + 30_000), nowMs: now + 30_000)
    assert(claimedModel.isStale && claimedModel.count(.review) == 0, "A snapshot cannot supply an inferred ending itself")
    // Turn records: completion identity without any runtime evidence (an SSH task).
    func recorded(_ key: String?, state: LiveState = .unknown, at: Double) -> LiveTask {
        LiveTask(id: "claude:local_remote-demo", provider: "claude", title: "Synthetic remote task", state: state,
                 resultKey: key, sourceURL: "claude://code/continue?session=local_remote-demo", observedAt: at,
                 evidence: state == .unknown ? "unavailable" : "live", updatedAt: at,
                 availabilityReason: state == .unknown ? "turn-record-only" : nil, completionTracking: LiveModel.turnRecord)
    }
    let turnDirectory = directory.appendingPathComponent("turn-record")
    let turns = LiveModel(stateDirectory: turnDirectory)
    turns.apply(cacheSnapshot(recorded("result:3", at: now), at: now), nowMs: now)
    assert(turns.count(.review) == 0 && turns.count(.running) == 0, "The first sight of a turn record is a quiet baseline")
    turns.apply(cacheSnapshot(recorded("result:3", at: now + 1_000), at: now + 1_000), nowMs: now + 1_000)
    assert(turns.count(.review) == 0)
    turns.apply(cacheSnapshot(recorded("result:4", at: now + 2_000), at: now + 2_000), nowMs: now + 2_000)
    assert(turns.count(.review) == 1 && turns.count(.running) == 0 && turns.canMarkReviewed(turns.currentResult!),
           "A new recorded turn queues with unknown runtime and is confirmable")
    let turnLedger = try Data(contentsOf: turnDirectory.appendingPathComponent("review-ledger.json"))
    turns.apply(cacheSnapshot(recorded("result:4", at: now + 3_000), at: now + 3_000), nowMs: now + 3_000)
    let turnLedgerAfter = try Data(contentsOf: turnDirectory.appendingPathComponent("review-ledger.json"))
    assert(turnLedgerAfter == turnLedger, "A later observation time alone does not rewrite the record")
    assert(!String(decoding: turnLedger, as: UTF8.self).contains("turn-record-only"),
           "Stored tasks stay loadable by earlier versions")
    let turnsReloaded = LiveModel(stateDirectory: turnDirectory)
    assert(turnsReloaded.ledgerError == nil && turnsReloaded.count(.review) == 1)
    turnsReloaded.apply(cacheSnapshot(recorded("result:5", at: now + 4_000), at: now + 4_000), nowMs: now + 4_000)
    assert(turnsReloaded.count(.review) == 1 && turnsReloaded.pendingResults.count == 2, "Two turns of one task count once")
    turnsReloaded.markReviewed(turnsReloaded.currentReviewGroup!)
    turnsReloaded.apply(cacheSnapshot(recorded("result:5", at: now + 5_000), at: now + 5_000), nowMs: now + 5_000)
    assert(turnsReloaded.count(.review) == 0, "Confirmed recorded turns do not return")
    turnsReloaded.apply(cacheSnapshot(recorded("error:1700000000000", at: now + 6_000), at: now + 6_000), nowMs: now + 6_000)
    assert(turnsReloaded.count(.review) == 1, "A recorded failure queues like a result")
    let fresh = LiveModel(stateDirectory: directory, persist: false)
    fresh.apply(cacheSnapshot(recorded(nil, at: now), at: now), nowMs: now)
    fresh.apply(cacheSnapshot(recorded("result:1", at: now + 1_000), at: now + 1_000), nowMs: now + 1_000)
    assert(fresh.count(.review) == 1, "The first turn of a task seen before it finished is not swallowed as a baseline")
    let idleOnlyModel = LiveModel(stateDirectory: directory, persist: false)
    idleOnlyModel.apply(cacheSnapshot(cacheIdle, at: now + 25_000), nowMs: now + 25_000)
    let firstAuthoritativeRead = LiveTask(id: cacheIdle.id, provider: "claude", title: cacheIdle.title, state: .read,
        resultKey: "result:confirmed-in-source", sourceURL: cacheIdle.sourceURL, observedAt: now + 26_000,
        evidence: "live", updatedAt: now + 26_000)
    idleOnlyModel.apply(cacheSnapshot(firstAuthoritativeRead, at: now + 26_000), nowMs: now + 26_000)
    assert(idleOnlyModel.count(.review) == 0, "Cached idle must not turn the first authoritative read into a new completion")
    for badState in [LiveState.read, .review] {
        let noReceipt = LiveModel(stateDirectory: directory, persist: false)
        noReceipt.apply(cacheSnapshot(cache(badState, observed: now, key: "result:fake-cache-result"), at: now), nowMs: now)
        assert(noReceipt.isStale && noReceipt.count(.review) == 0, "Cache cannot claim source read/completion receipts")
    }
    assert(LiveModel.validatedSourceURL("codex://threads/sample-a?hostId=ssh:machine-1") != nil)
    assert(LiveModel.validatedSourceURL("claude://code/cse_demo") != nil)
    assert(LiveModel.validatedSourceURL("claude://code/session_demo") != nil)
    for badURL in ["codex://threads/sample-a?hostId=remote&hostId=other", "codex://threads/sample-a?hostId=remote/unsafe",
        "codex://threads/sample-a?hostId=remote%2Funsafe", "codex://threads/sample%2Da?hostId=remote",
        "codex://someone@threads/sample-a?hostId=remote", "codex://threads/sample-a?hostId=remote&extra=1",
        "claude://code/session_demo?extra=1", "claude://code/session_demo%2Fother", "claude://code/session_demo/extra",
        "claude://someone@code/session_demo", "claude://code/session_demo\n"] {
        assert(LiveModel.validatedSourceURL(badURL) == nil, "Malformed source routes must be rejected")
    }
    for badTask in [
        LiveTask(id: "codex:continue", provider: "codex", title: "Synthetic mismatch", state: .read,
            resultKey: nil, sourceURL: "claude://code/continue?session=local_demo", observedAt: now, evidence: "live", updatedAt: now),
        LiveTask(id: "claude:session_expected", provider: "claude", title: "Synthetic mismatch", state: .read,
            resultKey: nil, sourceURL: "claude://code/session_other", observedAt: now, evidence: "live", updatedAt: now)
    ] {
        let wrongDestination = LiveModel(stateDirectory: directory, persist: false)
        wrongDestination.apply(LiveSnapshot(type: "snapshot", version: 1, generatedAt: now,
            providers: [ProviderState(id: badTask.provider, health: "live")], tasks: [badTask]), nowMs: now)
        assert(wrongDestination.isStale && wrongDestination.tasks.isEmpty)
    }
    let ledger = directory.appendingPathComponent("review-ledger.json")
    let corrupt = Data("not-json".utf8); try corrupt.write(to: ledger)
    let broken = LiveModel(stateDirectory: directory)
    assert(broken.ledgerError != nil)
    broken.apply(snapshot([task("codex:sample-b", .review, "result:turn-9")]), nowMs: now)
    assert(!broken.canMarkReviewed(broken.currentResult!))
    let preserved = try Data(contentsOf: ledger)
    assert(preserved == corrupt, "A corrupt ledger must not be silently overwritten")
    print("PASS: local review baseline/receipts, durable queue, stale state, cache TTL/receipt isolation, inferred cache endings, turn-record completions, old record decoding, exact remote URL validation, and corruption preservation.")
}
