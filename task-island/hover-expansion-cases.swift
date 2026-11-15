import Foundation

private struct HoverFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class ManualScheduler {
    struct Job {
        let deadline: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
        var fired = false
    }

    private(set) var now: TimeInterval = 0
    private(set) var jobs: [Job] = []

    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        let index = jobs.count
        jobs.append(Job(deadline: now + delay, action: action))
        return { [weak self] in self?.jobs[index].cancelled = true }
    }

    func advance(_ seconds: TimeInterval) {
        let target = now + seconds
        while let index = jobs.indices.filter({ !jobs[$0].cancelled && !jobs[$0].fired && jobs[$0].deadline <= target })
            .min(by: { jobs[$0].deadline < jobs[$1].deadline }) {
            now = jobs[index].deadline
            jobs[index].fired = true
            jobs[index].action()
        }
        now = target
    }

    // Deliberately bypass cancellation to exercise the controller's generation guard.
    func forceFire(_ index: Int) { jobs[index].action() }
}

@MainActor
private final class Fixture {
    let clock = ManualScheduler()
    var changes: [Bool] = []
    var controller: HoverExpansionController!

    init(expanded: Bool = false) {
        controller = HoverExpansionController(isExpanded: expanded, onChange: { [weak self] in
            self?.changes.append($0)
        }, schedule: clock.schedule)
    }
}

@main
struct HoverExpansionCases {
    @MainActor static func main() async throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw HoverFailure(description: message) }
        }
        var passed = 0
        func run(_ name: String, _ body: () throws -> Void) throws {
            try body()
            passed += 1
            print("PASS: " + name)
        }

        try run("enter opens at 120ms; leave closes at 300ms") {
            let f = Fixture()
            f.controller.pointerChanged(isInside: true)
            try require(f.clock.jobs[0].deadline == 0.120, "Opening must use 120ms")
            f.clock.advance(0.119)
            try require(f.changes.isEmpty, "Entry must be debounced")
            f.clock.advance(0.002)
            try require(f.changes == [true] && f.controller.isExpanded, "Hover must open without a click")
            f.controller.pointerChanged(isInside: false)
            try require(abs(f.clock.jobs[1].deadline - f.clock.now - 0.300) < 0.000001, "Closing must use 300ms")
            f.clock.advance(0.299)
            try require(f.changes == [true], "Leave must be debounced")
            f.clock.advance(0.002)
            try require(f.changes == [true, false] && !f.controller.isExpanded, "Leave must collapse")
        }
        try run("rapid crossing cancels opening, including a stale callback") {
            let f = Fixture()
            f.controller.pointerChanged(isInside: true)
            f.clock.advance(0.050)
            f.controller.pointerChanged(isInside: false)
            try require(f.clock.jobs[0].cancelled, "Leaving must cancel the scheduled task")
            f.clock.forceFire(0)
            f.clock.advance(1)
            try require(f.changes.isEmpty, "A canceled opening must never reopen")
        }
        try run("old entry cannot open during a newer entry debounce") {
            let f = Fixture()
            f.controller.pointerChanged(isInside: true)
            f.controller.pointerChanged(isInside: false)
            f.controller.pointerChanged(isInside: true)
            f.clock.forceFire(0)
            try require(f.changes.isEmpty, "Old generation must not bypass the new delay")
            f.clock.advance(0.121)
            try require(f.changes == [true], "New entry should still open")
        }
        try run("reentry cancels collapse and expanded-body containment holds open") {
            let f = Fixture()
            f.controller.pointerChanged(isInside: true)
            f.clock.advance(0.121)
            f.controller.pointerChanged(isInside: false)
            f.clock.advance(0.200)
            f.controller.pointerChanged(isInside: true)
            try require(f.clock.jobs[1].cancelled, "Reentry must cancel close")
            f.clock.forceFire(1)
            f.controller.pointerChanged(isInside: true)
            f.clock.advance(10)
            try require(f.changes == [true], "The whole expanded body must remain open")
            f.controller.pointerChanged(isInside: false)
            f.clock.advance(0.301)
            try require(f.changes == [true, false], "A later leave must still close")
        }
        try run("repeated pointer samples do not restart either debounce") {
            let f = Fixture()
            f.controller.pointerChanged(isInside: true)
            f.clock.advance(0.100)
            f.controller.pointerChanged(isInside: true)
            f.clock.advance(0.021)
            f.controller.pointerChanged(isInside: false)
            f.clock.advance(0.250)
            f.controller.pointerChanged(isInside: false)
            f.clock.advance(0.051)
            try require(f.changes == [true, false] && f.clock.jobs.count == 2, "Repeated samples must not starve timers")
        }
        try run("manual collapse cancels opening until an actual leave and reentry") {
            let f = Fixture()
            f.controller.pointerChanged(isInside: true)
            f.controller.expansionChanged(false)
            f.clock.forceFire(0)
            f.controller.pointerChanged(isInside: true)
            f.clock.advance(1)
            try require(f.changes.isEmpty, "Manual collapse must suppress hover reopening")
            f.controller.pointerChanged(isInside: false)
            f.controller.pointerChanged(isInside: true)
            f.clock.advance(0.121)
            try require(f.changes == [true], "A genuine new entry clears suppression")
        }
        try run("manual collapse of an open body stays closed under the pointer") {
            let f = Fixture()
            f.controller.pointerChanged(isInside: true)
            f.clock.advance(0.121)
            f.controller.expansionChanged(false)
            f.controller.pointerChanged(isInside: true)
            f.controller.setInteractionActive(true)
            f.controller.setInteractionActive(false)
            f.clock.advance(1)
            try require(f.changes == [true] && !f.controller.isExpanded, "Menu resume must preserve manual suppression")
        }
        try run("explicit expansion inside clears suppression and closes after leave") {
            let f = Fixture()
            f.controller.pointerChanged(isInside: true)
            f.controller.expansionChanged(false)
            f.controller.expansionChanged(true)
            f.clock.forceFire(0)
            try require(f.changes.isEmpty && f.controller.isExpanded, "Synchronization must not echo onChange")
            f.controller.pointerChanged(isInside: false)
            f.clock.advance(0.301)
            try require(f.changes == [false], "Explicit opening inside must arm leave-to-close")
        }
        try run("initial expanded state waits for enter then leave") {
            let f = Fixture(expanded: true)
            f.controller.pointerChanged(isInside: false)
            f.controller.setInteractionActive(true)
            f.controller.setInteractionActive(false)
            f.clock.advance(1)
            try require(f.changes.isEmpty && f.clock.jobs.isEmpty, "Outside initial state must not auto-close")
            f.controller.pointerChanged(isInside: true)
            f.controller.pointerChanged(isInside: false)
            f.clock.advance(0.301)
            try require(f.changes == [false], "An actual enter/leave arms collapse")
        }
        try run("outside keyboard reopening invalidates old close and hover history") {
            let f = Fixture(expanded: true)
            f.controller.pointerChanged(isInside: true)
            f.controller.pointerChanged(isInside: false)
            f.controller.expansionChanged(false)
            f.controller.expansionChanged(true)
            f.clock.forceFire(0)
            f.controller.setInteractionActive(true)
            f.controller.setInteractionActive(false)
            f.clock.advance(1)
            try require(f.changes.isEmpty && f.controller.isExpanded, "Outside reopen must wait for a fresh entry")
            f.controller.pointerChanged(isInside: true)
            f.controller.pointerChanged(isInside: false)
            f.clock.advance(0.301)
            try require(f.changes == [false], "Fresh visit must enable collapse")
        }
        try run("menu suspends close; latest outside position resumes full close delay") {
            let f = Fixture(expanded: true)
            f.controller.pointerChanged(isInside: true)
            f.controller.pointerChanged(isInside: false)
            f.controller.setInteractionActive(true)
            f.clock.forceFire(0)
            f.clock.advance(1)
            try require(f.changes.isEmpty && f.clock.jobs[0].cancelled, "Tracking menu must hold expansion")
            f.controller.setInteractionActive(false)
            f.clock.advance(0.299)
            try require(f.changes.isEmpty, "Menu end starts a fresh delay")
            f.clock.advance(0.002)
            try require(f.changes == [false], "Outside menu end must eventually close")
        }
        try run("menu remembers reentry and holds open after ending inside") {
            let f = Fixture(expanded: true)
            f.controller.pointerChanged(isInside: true)
            f.controller.setInteractionActive(true)
            f.controller.pointerChanged(isInside: false)
            f.controller.pointerChanged(isInside: true)
            f.controller.setInteractionActive(false)
            f.clock.advance(1)
            try require(f.changes.isEmpty && f.clock.jobs.isEmpty, "Latest inside sample must win")
            f.controller.pointerChanged(isInside: false)
            f.clock.advance(0.301)
            try require(f.changes == [false], "Later leave must close")
        }
        try run("menu suspends opening and resumes from latest inside position") {
            let f = Fixture()
            f.controller.pointerChanged(isInside: true)
            f.controller.setInteractionActive(true)
            f.clock.forceFire(0)
            f.clock.advance(1)
            try require(f.changes.isEmpty, "Opening must not fire during menu tracking")
            f.controller.setInteractionActive(false)
            f.clock.advance(0.100)
            f.controller.setInteractionActive(false)
            f.clock.advance(0.021)
            try require(f.changes == [true], "Resume must open; duplicate menu-end must not reset delay")
        }
        try run("menu entry then exit uses latest outside position without opening") {
            let f = Fixture()
            f.controller.setInteractionActive(true)
            f.controller.pointerChanged(isInside: true)
            f.controller.pointerChanged(isInside: false)
            f.controller.setInteractionActive(false)
            f.clock.advance(1)
            try require(f.changes.isEmpty && f.clock.jobs.isEmpty, "A suspended crossing must not open")
        }
        try run("menu keyboard opening outside stays open until a real visit") {
            let f = Fixture()
            f.controller.setInteractionActive(true)
            f.controller.expansionChanged(true)
            f.controller.setInteractionActive(false)
            f.clock.advance(1)
            try require(f.changes.isEmpty && f.controller.isExpanded, "Menu reopening outside must not immediately close")
            f.controller.pointerChanged(isInside: true)
            f.controller.setInteractionActive(true)
            f.controller.pointerChanged(isInside: false)
            f.clock.advance(1)
            try require(f.changes.isEmpty, "Leave during menu tracking must be held")
            f.controller.setInteractionActive(false)
            f.clock.advance(0.301)
            try require(f.changes == [false], "Menu end must honor the recorded leave")
        }
        try run("hide cancels pending open; fresh entry can reuse controller") {
            let f = Fixture()
            f.controller.pointerChanged(isInside: true)
            f.controller.cancel()
            f.controller.cancel()
            f.clock.forceFire(0)
            f.controller.setInteractionActive(false)
            f.clock.advance(1)
            try require(f.changes.isEmpty && f.clock.jobs[0].cancelled, "Hide must discard callbacks")
            f.controller.pointerChanged(isInside: true)
            f.clock.forceFire(0)
            try require(f.changes.isEmpty, "Old callback must remain stale after reuse")
            f.clock.advance(0.121)
            try require(f.changes == [true], "Fresh entry after showing must work")
        }
        try run("quit cancels a pending close without emitting a change") {
            let f = Fixture(expanded: true)
            f.controller.pointerChanged(isInside: true)
            f.controller.pointerChanged(isInside: false)
            f.controller.cancel()
            f.clock.forceFire(0)
            f.clock.advance(1)
            try require(f.changes.isEmpty && f.clock.jobs[0].cancelled, "Quit must discard pending collapse")
        }
        try run("cancel resets suspended pointer history") {
            let f = Fixture(expanded: true)
            f.controller.pointerChanged(isInside: true)
            f.controller.pointerChanged(isInside: false)
            f.controller.setInteractionActive(true)
            f.controller.cancel()
            f.clock.forceFire(0)
            f.controller.setInteractionActive(false)
            f.clock.advance(1)
            try require(f.changes.isEmpty && f.controller.isExpanded, "Cancel must not emit changes or resume an old leave")
        }
        try run("callbacks may synchronously synchronize a manual collapse") {
            let clock = ManualScheduler()
            var changes: [Bool] = []
            var controller: HoverExpansionController!
            controller = HoverExpansionController(onChange: { expanded in
                changes.append(expanded)
                controller.expansionChanged(false)
            }, schedule: clock.schedule)
            controller.pointerChanged(isInside: true)
            clock.advance(0.121)
            clock.forceFire(0)
            controller.pointerChanged(isInside: true)
            clock.advance(1)
            try require(changes == [true] && !controller.isExpanded, "Callback synchronization must not leave stale work")
        }
        try run("scheduled closures do not retain a discarded controller") {
            let clock = ManualScheduler()
            var changes: [Bool] = []
            var controller: HoverExpansionController? = HoverExpansionController(onChange: { changes.append($0) }, schedule: clock.schedule)
            let isReleased = { [weak controller] in controller == nil }
            controller?.pointerChanged(isInside: true)
            controller = nil
            clock.forceFire(0)
            try require(isReleased() && changes.isEmpty, "Pending work must not keep the controller alive")
        }

        // Use real default delays with generous polling bounds, not timing-sensitive sleeps.
        var asyncChanges: [Bool] = []
        let live = HoverExpansionController(onChange: { asyncChanges.append($0) })
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try require(condition(), "Async scheduling timed out")
        }
        live.pointerChanged(isInside: true)
        try require(asyncChanges.isEmpty, "Production entry must return without synchronous expansion")
        try await waitUntil { asyncChanges == [true] }
        live.pointerChanged(isInside: false)
        try await waitUntil { asyncChanges == [true, false] }
        live.pointerChanged(isInside: true)
        live.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        try require(asyncChanges == [true, false], "Production cancel must not reopen")
        print("PASS: default async scheduler expands, collapses, and cancels without blocking")
        passed += 1
        print("PASS: \(passed) hover-expansion scenarios; Foundation only; no app integration or user data.")
    }
}
