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
        self.schedule = schedule ?? { delay, action in
            let task = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled else { return }
                action()
            }
            return { task.cancel() }
        }
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
