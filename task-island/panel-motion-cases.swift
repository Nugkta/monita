import Foundation

private struct MotionFailure: Error, CustomStringConvertible { let description: String }

@main
private struct PanelMotionCases {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw MotionFailure(description: message) }
    }
    static func run(_ name: String, _ body: () throws -> Void) throws {
        do { try body(); print("PASS: \(name)") }
        catch { print("FAIL: \(name): \(error)"); throw error }
    }
    static let compact = PanelMotion.Frame(x: 648, top: 932, width: 216, height: 34)
    static let open = PanelMotion.Frame(x: 536, top: 932, width: 440, height: 210)

    /// Steps at an uneven cadence until settled; returns elapsed seconds and every frame seen.
    static func play(_ motion: inout PanelMotion, cadence: [Double] = [1.0 / 120.0], limit: Double = 3)
        -> (time: Double, frames: [PanelMotion.Frame], reveals: [Double]) {
        var time = 0.0, index = 0
        var frames: [PanelMotion.Frame] = [], reveals: [Double] = []
        while !motion.isSettled && time < limit {
            let dt = cadence[index % cadence.count]; index += 1
            motion.step(dt: dt); time += dt
            frames.append(motion.frame); reveals.append(motion.reveal)
        }
        return (time, frames, reveals)
    }

    static func main() throws {
        try run("opening settles on the target quickly and never overshoots from rest") {
            var motion = PanelMotion(frame: compact, reveal: 0)
            motion.retarget(open, reveal: 1)
            let result = play(&motion)
            try require(motion.isSettled && result.time > 0.15 && result.time < 0.40, "Opening took \(result.time)s")
            try require(result.frames.allSatisfy { $0.width <= open.width + 0.5 && $0.height <= open.height + 0.5 },
                        "A panel opening from rest must not grow past its target")
            try require(zip(result.frames, result.frames.dropFirst()).allSatisfy { $1.width >= $0.width && $1.height >= $0.height },
                        "Opening is monotonic")
            try require(zip(result.reveals, result.reveals.dropFirst()).allSatisfy { $1 >= $0 }, "Reveal is monotonic")
        }
        try run("closing is quicker than opening and ends exactly compact") {
            var opening = PanelMotion(frame: compact, reveal: 0); opening.retarget(open, reveal: 1)
            var closing = PanelMotion(frame: open, reveal: 1); closing.retarget(compact, reveal: 0)
            let a = play(&opening), b = play(&closing)
            try require(b.time < a.time && b.time > 0.1, "Closing \(b.time)s should be shorter than opening \(a.time)s")
            try require(abs(closing.frame.width - compact.width) < 0.5 && closing.reveal < 0.004, "Closing ends compact")
        }
        try run("the top edge does not move when both frames share it") {
            var motion = PanelMotion(frame: compact, reveal: 0); motion.retarget(open, reveal: 1)
            let result = play(&motion)
            try require(result.frames.allSatisfy { $0.top == compact.top }, "The anchored top edge must stay still")
        }
        try run("frames sit on the half-point grid and are never empty") {
            var motion = PanelMotion(frame: compact, reveal: 0); motion.retarget(open, reveal: 1)
            let result = play(&motion, cadence: [0.0041, 0.0113, 0.0079])
            for frame in result.frames {
                for value in [frame.x, frame.top, frame.width, frame.height] {
                    try require((value * 2).rounded() == value * 2, "\(value) is off the half-point grid")
                }
                try require(frame.width >= 1 && frame.height >= 1, "A frame must keep a positive size")
            }
        }
        try run("uneven and coarse ticks follow the same path as fine ones") {
            var fine = PanelMotion(frame: compact, reveal: 0); fine.retarget(open, reveal: 1)
            var coarse = fine
            for _ in 0..<24 { fine.step(dt: 0.005) }          // 0.12s in 24 steps
            for dt in [0.03, 0.05, 0.04] { coarse.step(dt: dt) } // 0.12s in 3 steps
            try require(abs(fine.frame.width - coarse.frame.width) <= 0.5 && abs(fine.reveal - coarse.reveal) < 0.001,
                        "The path must depend on elapsed time, not on tick count")
        }
        try run("a stalled run loop is taken as one bounded step") {
            var motion = PanelMotion(frame: compact, reveal: 0); motion.retarget(open, reveal: 1)
            var bounded = motion
            motion.step(dt: 5); bounded.step(dt: PanelMotion.longestStep)
            try require(motion.frame == bounded.frame && !motion.isSettled, "A long pause must not teleport the panel")
            motion.step(dt: -1)
            try require(motion.frame == bounded.frame, "A backwards clock is ignored")
        }
        try run("reversing mid-flight turns around without a jump") {
            var motion = PanelMotion(frame: compact, reveal: 0); motion.retarget(open, reveal: 1)
            for _ in 0..<10 { motion.step(dt: 1.0 / 120.0) }
            let before = motion.frame, revealBefore = motion.reveal
            motion.retarget(compact, reveal: 0)
            try require(motion.frame == before && motion.reveal == revealBefore, "Retargeting alone moves nothing")
            motion.step(dt: 1.0 / 120.0)
            let after = motion.frame
            try require(abs(after.width - before.width) < 8 && abs(after.height - before.height) < 8,
                        "The first frame after a reversal stays next to the last one")
            let result = play(&motion)
            try require(motion.isSettled && abs(motion.frame.width - compact.width) < 0.5 && result.time < 0.5, "It still lands compact")
            try require(result.frames.allSatisfy { $0.width >= compact.width - 0.5 && $0.height >= compact.height - 0.5 },
                        "A reversal must not shrink past the compact size")
        }
        try run("reopening during a close resumes from the current reveal") {
            var motion = PanelMotion(frame: open, reveal: 1); motion.retarget(compact, reveal: 0)
            for _ in 0..<8 { motion.step(dt: 1.0 / 120.0) }
            let partway = motion.reveal
            try require(partway > 0.05 && partway < 0.95, "The close is in progress")
            motion.retarget(open, reveal: 1)
            let result = play(&motion)
            try require(result.reveals.allSatisfy { $0 >= 0 && $0 <= 1 }, "Reveal stays within its range")
            try require(motion.isSettled && motion.reveal > 0.996 && abs(motion.frame.width - open.width) <= 0.5, "It reopens fully")
        }
        try run("a height-only change keeps the reveal fully open") {
            var motion = PanelMotion(frame: open, reveal: 1)
            var taller = open; taller.height = 272
            motion.retarget(taller, reveal: 1)
            let result = play(&motion)
            try require(result.reveals.allSatisfy { $0 == 1 } && abs(motion.frame.height - 272) <= 0.5 && motion.frame.width == open.width,
                        "Switching tabs resizes the panel without touching the reveal")
        }
        try run("a motion with nowhere to go is already settled") {
            var motion = PanelMotion(frame: compact, reveal: 0)
            try require(motion.isSettled, "At rest")
            motion.retarget(compact, reveal: 0)
            try require(motion.isSettled && motion.frame == compact, "Same target")
        }
        try run("content follows the frame in and leaves ahead of it") {
            try require(PanelReveal.bodyOpacity(0) == 0 && PanelReveal.bodyOpacity(0.25) == 0 && PanelReveal.bodyOpacity(1) == 1,
                        "The list is invisible until there is room for it")
            try require(PanelReveal.bodyOpacity(0.8) == 1, "The list is fully visible before the frame stops")
            try require(PanelReveal.bodyOffset(1) == 0 && PanelReveal.bodyOffset(0) == -8, "The list settles from 8 points above")
            try require(PanelReveal.labelAmount(0) == 0 && PanelReveal.labelAmount(0.2) == 0 && PanelReveal.labelAmount(1) == 1, "Labels")
            try require(PanelReveal.cornerRadius(0) == 17 && PanelReveal.cornerRadius(1) == 12 && PanelReveal.cornerRadius(7) == 12, "Corners")
            var last = -1.0
            for step in 0...100 {
                let value = PanelReveal.bodyOpacity(Double(step) / 100)
                try require(value >= last && value >= 0 && value <= 1, "Opacity is monotonic and bounded")
                last = value
            }
        }
        try run("labels only ask for width the widening bar already has") {
            // Compact content needs about 190 points; the three labels add about 140.
            for step in 0...100 {
                let reveal = Double(step) / 100
                let available = 216 + (440 - 216) * reveal
                let needed = 190 + 140 * PanelReveal.labelAmount(reveal)
                try require(needed <= available, "At reveal \(reveal) labels need \(needed) of \(available)")
            }
        }
        print("PASS: 12 panel-motion scenarios; Foundation only; no window, display or user data.")
    }
}
