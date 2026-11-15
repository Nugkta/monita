import CoreGraphics
import Foundation

@MainActor
final class HoverExpansionController {
    // A scheduler must defer its action and return a cancellation closure.
    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)

    private(set) var isExpanded: Bool
    private let onChange: (Bool) -> Void
    private let schedule: Schedule
    private var isInside = false
    private var hasEntered = false
    private var suppressOpening = false
    private var interactionActive = false
    private var generation: UInt64 = 0
    private var cancelPending: (@MainActor () -> Void)?

    init(isExpanded: Bool = false, onChange: @escaping (Bool) -> Void,
         schedule: Schedule? = nil) {
        self.isExpanded = isExpanded
        self.onChange = onChange
        self.schedule = schedule ?? Self.defaultSchedule
    }

    /// Runs `action` after `delay` on the main actor; the returned closure cancels it.
    static func defaultSchedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        let task = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }

    // Supply containment for the whole panel, including its expanded body.
    func pointerChanged(isInside: Bool) {
        guard self.isInside != isInside else { return }
        self.isInside = isInside
        if isInside {
            hasEntered = true
        } else {
            suppressOpening = false
        }
        resumeHoverDecision()
    }

    // Synchronization only: external changes do not echo through onChange.
    func expansionChanged(_ expanded: Bool) {
        discardPending()
        isExpanded = expanded
        suppressOpening = !expanded && isInside
        hasEntered = isInside
    }

    func setInteractionActive(_ active: Bool) {
        guard interactionActive != active else { return }
        interactionActive = active
        resumeHoverDecision()
    }

    // Hide/quit resets hover history; a later fresh entry can reuse this helper.
    func cancel() {
        discardPending()
        isInside = false
        hasEntered = false
        suppressOpening = false
        interactionActive = false
    }

    private func resumeHoverDecision() {
        discardPending()
        guard !interactionActive else { return }
        if isInside && !isExpanded && !suppressOpening {
            deferChange(to: true, after: 0.120)
        } else if !isInside && isExpanded && hasEntered {
            deferChange(to: false, after: 0.300)
        }
    }

    private func deferChange(to expanded: Bool, after delay: TimeInterval) {
        let expectedGeneration = generation
        cancelPending = schedule(delay) { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.discardPending()
            guard self.isExpanded != expanded else { return }
            self.isExpanded = expanded
            self.onChange(expanded)
        }
    }

    private func discardPending() {
        generation &+= 1
        let cancellation = cancelPending
        cancelPending = nil
        cancellation?()
    }
}

/// Selects the tab the pointer moves onto, after a short dwell, without a click.
///
/// Only the pointer's own movement counts. Both the previous and the new pointer
/// location are tested against the tabs' current frames, so when the panel opens
/// and the tabs widen under a pointer that is not moving, nothing is selected.
/// Points and frames must be in one coordinate space that does not move with the
/// panel (screen coordinates).
@MainActor
final class HoverTabSelector<Tab: Hashable> {
    typealias Schedule = HoverExpansionController.Schedule

    /// Shorter than the 120ms hover-open delay, so a bar entered on a tab opens on that tab.
    nonisolated static var defaultDwell: TimeInterval { 0.100 }

    private let dwell: TimeInterval
    private let onSelect: (Tab) -> Void
    private let schedule: Schedule
    private var lastPoint: CGPoint?
    private var generation: UInt64 = 0
    private var cancelPending: (@MainActor () -> Void)?
    private(set) var pendingTab: Tab?

    init(dwell: TimeInterval = HoverTabSelector.defaultDwell, onSelect: @escaping (Tab) -> Void, schedule: Schedule? = nil) {
        self.dwell = dwell
        self.onSelect = onSelect
        self.schedule = schedule ?? HoverExpansionController.defaultSchedule
    }

    static func tab(at point: CGPoint, in tabs: [Tab: CGRect]) -> Tab? {
        tabs.first { $0.value.contains(point) }?.key
    }

    /// A real pointer movement inside the panel, with each tab's frame as laid out now.
    func pointerMoved(to point: CGPoint, tabs: [Tab: CGRect]) {
        let current = Self.tab(at: point, in: tabs)
        let previous = lastPoint.flatMap { Self.tab(at: $0, in: tabs) }
        lastPoint = point
        // Moving within one tab keeps any pending selection; so does a layout change
        // under a still pointer, because then both points fall in the same tab.
        guard current != previous else { return }
        discardPending()
        guard let current else { return }
        pendingTab = current
        let expectedGeneration = generation
        cancelPending = schedule(dwell) { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.discardPending()
            self.onSelect(current)
        }
    }

    /// The pointer is at `point` inside the panel without having moved there, e.g. after
    /// a drag ends or the panel is laid out anew. Only movement from here selects.
    func pointerSettled(at point: CGPoint) {
        discardPending()
        lastPoint = point
    }

    /// The pointer left the panel, the panel was hidden, or a menu took over.
    func pointerLeft() {
        discardPending()
        lastPoint = nil
    }

    private func discardPending() {
        generation &+= 1
        pendingTab = nil
        let cancellation = cancelPending
        cancelPending = nil
        cancellation?()
    }
}
