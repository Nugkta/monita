import Foundation

/// Applies only the exact review records the user confirmed in this conversation.
/// No UI, source navigation or source observers are started.
@MainActor func confirmCapturedReviews(from path: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count <= 4_000_000 else { throw CocoaError(.fileReadCorruptFile) }
    let ids = try JSONDecoder().decode([String].self, from: data)
    guard ids.count <= 10_000, ids.allSatisfy({ $0.count <= 8_192 }) else { throw CocoaError(.fileReadCorruptFile) }
    let captured = Set(ids)
    // Original project name, kept so existing review history carries over.
    let state = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TaskIsland", isDirectory: true)
    let model = LiveModel(stateDirectory: state)
    guard model.ledgerError == nil else { throw CocoaError(.fileReadCorruptFile) }
    var confirmed = 0
    for group in model.pendingReviewGroups {
        let items = group.items.filter { captured.contains($0.id) }
        guard let last = items.last else { continue }
        let subset = ReviewGroup(id: group.id, task: last.task, items: items)
        guard model.canMarkReviewed(subset) else { throw CocoaError(.fileReadCorruptFile) }
        model.markReviewed(subset)
        guard model.ledgerError == nil else { throw CocoaError(.fileWriteUnknown) }
        confirmed += items.count
    }
    let report: [String: Any] = ["confirmedCapturedResults": confirmed,
        "pendingTasks": model.count(.review), "pendingResults": model.pendingResults.count,
        "sourceObserversStarted": false]
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
}
