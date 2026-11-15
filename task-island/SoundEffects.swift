import AppKit
import Foundation

@MainActor
final class SoundEffects {
    private static let preferenceKey = "soundEffectsEnabled"
    private let defaults: UserDefaults
    private let now: () -> TimeInterval
    private let play: ((URL, Float) -> Void)?
    private let stopPlayback: (() -> Void)?
    private let automaticScheduling: Bool
    private var sound: NSSound?
    private var scheduledPlayback: Task<Void, Never>?
    private var pending: AttentionEvent?
    private var deadline: TimeInterval?
    private var lastPlayedAt: TimeInterval?
    private(set) var isEnabled: Bool

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         play: ((URL, Float) -> Void)? = nil,
         stopPlayback: (() -> Void)? = nil,
         automaticScheduling: Bool = true) {
        self.defaults = defaults
        self.now = now
        self.play = play
        self.stopPlayback = stopPlayback
        self.automaticScheduling = automaticScheduling
        isEnabled = defaults.object(forKey: Self.preferenceKey) == nil
            ? true : defaults.bool(forKey: Self.preferenceKey)
    }

    func setEnabled(_ value: Bool) {
        isEnabled = value
        defaults.set(value, forKey: Self.preferenceKey)
        if !value { stop() }
    }

    func handle(_ event: AttentionEvent) {
        guard isEnabled else { return }
        // One fixed window per burst; more events cannot postpone it forever.
        if pending == nil {
            pending = event
            deadline = max(now() + 0.15, lastPlayedAt.map { $0 + 1 } ?? 0)
            schedule()
        } else if case .input = event {
            pending = .input
        }
    }

    func stop() {
        scheduledPlayback?.cancel()
        scheduledPlayback = nil
        pending = nil
        deadline = nil
        lastPlayedAt = nil
        stopCurrentPlayback()
    }

    // Internal for deterministic tests: production calls this after an async delay.
    func flush() {
        scheduledPlayback?.cancel()
        scheduledPlayback = nil
        guard isEnabled, let event = pending, let deadline else { return }
        let time = now()
        guard time >= deadline else { schedule(); return }
        pending = nil
        self.deadline = nil
        lastPlayedAt = time

        let filename: String
        switch event {
        case .completed: filename = "Glass.aiff"
        case .input: filename = "Pop.aiff"
        }
        let url = URL(fileURLWithPath: "/System/Library/Sounds").appendingPathComponent(filename)
        stopCurrentPlayback()
        if let play {
            play(url, 0.35)
        } else {
            sound = NSSound(contentsOf: url, byReference: true)
            sound?.volume = 0.35
            sound?.play()
        }
    }

    private func schedule() {
        guard automaticScheduling, let deadline else { return }
        let delay = UInt64(max(0, deadline - now()) * 1_000_000_000)
        scheduledPlayback = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            self?.flush()
        }
    }

    private func stopCurrentPlayback() {
        sound?.stop()
        sound = nil
        stopPlayback?()
    }
}
