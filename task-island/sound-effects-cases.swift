import Foundation

private struct SoundFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class SoundFixture {
    let defaults: UserDefaults
    private let suite = "task-island-sound-cases-" + UUID().uuidString
    var time: TimeInterval = 100
    var cues: [(url: URL, volume: Float, time: TimeInterval)] = []
    var stops = 0

    init() { defaults = UserDefaults(suiteName: suite)! }

    func make() -> SoundEffects {
        SoundEffects(defaults: defaults, now: { [unowned self] in self.time },
                     play: { [unowned self] url, volume in
                         self.cues.append((url, volume, self.time))
                     }, stopPlayback: { [unowned self] in self.stops += 1 },
                     automaticScheduling: false)
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

@main
struct SoundEffectsCases {
    @MainActor static func main() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw SoundFailure(description: message) }
        }
        var passed = 0
        func run(_ name: String, _ body: (SoundFixture) throws -> Void) throws {
            let fixture = SoundFixture()
            defer { fixture.cleanUp() }
            try body(fixture)
            passed += 1
            print("PASS: " + name)
        }

        try run("unset preference defaults on; explicit off and on survive recreation") { f in
            let sounds = f.make()
            try require(sounds.isEnabled, "An absent setting must default ON")
            try require(f.defaults.object(forKey: "soundEffectsEnabled") == nil,
                        "Reading the default must not rewrite preferences")
            sounds.setEnabled(false)
            try require(!sounds.isEnabled && !f.make().isEnabled,
                        "Explicit OFF must persist and must not be replaced by the default")
            try require(f.defaults.object(forKey: "soundEffectsEnabled") as? Bool == false,
                        "Use the exact soundEffectsEnabled preference key")
            sounds.setEnabled(true)
            try require(sounds.isEnabled && f.make().isEnabled, "Explicit ON must persist")
        }
        try run("completed and input map to quiet distinct local cues") { f in
            let sounds = f.make()
            sounds.handle(.completed)
            sounds.flush()
            try require(f.cues.isEmpty, "handle must never play synchronously")
            f.time += 0.2
            sounds.flush()
            sounds.handle(.input)
            f.time += 1.1
            sounds.flush()
            try require(f.cues.map { $0.url.path } == ["/System/Library/Sounds/Glass.aiff",
                                                     "/System/Library/Sounds/Pop.aiff"],
                        "Both events must use the requested distinct macOS sounds")
            try require(f.cues.allSatisfy { abs($0.volume - 0.35) < 0.001 },
                        "Set per-sound quiet volume, not system volume")
            try require(f.stops == 2, "Stop previous playback before starting any new cue")
        }
        try run("a completion burst coalesces without extending the initial window") { f in
            let sounds = f.make()
            sounds.handle(.completed)
            f.time += 0.1
            for _ in 0..<100 { sounds.handle(.completed) }
            sounds.flush()
            try require(f.cues.isEmpty, "Wait for the original coalescing deadline")
            f.time += 0.06
            sounds.flush()
            sounds.flush()
            try require(f.cues.count == 1, "A burst must yield one cue at its original deadline")
        }
        try run("input wins mixed bursts in either arrival order") { f in
            let sounds = f.make()
            for events: [AttentionEvent] in [[.completed, .input, .completed], [.input, .completed, .input]] {
                for event in events { sounds.handle(event) }
                f.time += 1.1
                sounds.flush()
            }
            try require(f.cues.count == 2 && f.cues.allSatisfy { $0.url.lastPathComponent == "Pop.aiff" },
                        "Completion must never overwrite pending input")
        }
        try run("rate limit keeps a single pending cue with input priority") { f in
            let sounds = f.make()
            sounds.handle(.completed)
            f.time += 0.2
            sounds.flush()
            sounds.handle(.completed)
            f.time += 0.2
            sounds.flush()
            try require(f.cues.count == 1, "The coalescing window must not bypass the rate limit")
            for _ in 0..<100 { sounds.handle(.completed) }
            sounds.handle(.input)
            f.time += 0.81
            sounds.flush()
            sounds.flush()
            try require(f.cues.count == 2 && f.cues[1].url.lastPathComponent == "Pop.aiff",
                        "Only one priority cue may survive the cooldown")
            try require(f.cues[1].time - f.cues[0].time >= 1, "Cues must be at least one second apart")
            f.time += 10
            sounds.flush()
            try require(f.cues.count == 2, "A burst cannot leave a playback backlog")
        }
        try run("mute cancels pending and active playback; enabling never replays history") { f in
            let sounds = f.make()
            sounds.handle(.completed)
            f.time += 0.2
            sounds.flush()
            sounds.handle(.input)
            let stops = f.stops
            sounds.setEnabled(false)
            try require(f.stops == stops + 1, "Mute must stop playback immediately")
            sounds.handle(.input)
            f.time += 2
            sounds.flush()
            sounds.setEnabled(true)
            sounds.flush()
            try require(f.cues.count == 1, "Muted and previously queued events must be forgotten")
            sounds.handle(.completed)
            f.time += 0.2
            sounds.flush()
            try require(f.cues.count == 2 && f.cues[1].url.lastPathComponent == "Glass.aiff",
                        "Fresh events after enabling must still play")
        }
        try run("muting before the first cue cancels the coalescing window") { f in
            let sounds = f.make()
            sounds.handle(.input)
            sounds.setEnabled(false)
            sounds.setEnabled(true)
            f.time += 2
            sounds.flush()
            try require(f.cues.isEmpty, "Re-enabling before a deadline must not revive its event")
        }
        try run("stop cancels queued playback without disabling later fresh events") { f in
            let sounds = f.make()
            sounds.handle(.input)
            sounds.stop()
            sounds.stop()
            f.time += 2
            sounds.flush()
            try require(f.cues.isEmpty && sounds.isEnabled, "Stop must clear the queue, not the preference")
            sounds.handle(.completed)
            f.time += 0.2
            sounds.flush()
            sounds.handle(.input)
            let stops = f.stops
            sounds.stop()
            try require(f.stops == stops + 1, "Stop must stop active playback immediately")
            f.time += 2
            sounds.flush()
            try require(f.cues.count == 1, "Stop must cancel cooldown-queued playback too")
            sounds.handle(.input)
            f.time += 0.2
            sounds.flush()
            try require(f.cues.count == 2 && f.cues[1].url.lastPathComponent == "Pop.aiff",
                        "Later fresh events must work after stop")
        }
        print("PASS: \(passed) sound-effects scenarios; fake playback and clock only; no sound played.")
    }
}
