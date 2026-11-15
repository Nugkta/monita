import AppKit
import SwiftUI
import Combine
import Darwin

// Original native shell. The separate bridge supplies reduced local metadata;
// no prompt, answer, tool payload, credential, or source-app settings are read here.
struct LaunchOptions {
    var stateDirectory: URL
    var smokeSeconds: Double?
    var reportURL: URL?
    var expanded: Bool
    var floating: Bool
    var fixture: String?

    static func parse(_ args: [String]) throws -> LaunchOptions {
        enum Invalid: Error { case arguments }
        func value(_ flag: String) throws -> String? {
            guard let index = args.firstIndex(of: flag) else { return nil }
            guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else { throw Invalid.arguments }
            return args[index + 1]
        }
        // The data folder keeps the project's original name, so review history and
        // settings from before the rename to Monita carry over.
        let defaultState = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskIsland", isDirectory: true)
        var state = defaultState
        if let path = try value("--state-dir") {
            guard NSString(string: path).isAbsolutePath else { throw Invalid.arguments }
            state = URL(fileURLWithPath: path, isDirectory: true)
        }
        var smoke: Double?
        if let text = try value("--smoke-seconds") {
            guard let number = Double(text), number.isFinite, number > 0, number <= 120 else { throw Invalid.arguments }
            smoke = number
        }
        var report: URL?
        if let path = try value("--report") {
            guard NSString(string: path).isAbsolutePath else { throw Invalid.arguments }
            report = URL(fileURLWithPath: path)
        }
        let fixture = try value("--ui-fixture")
        if let fixture, !UIFixture.names.contains(fixture) { throw Invalid.arguments }
        return LaunchOptions(stateDirectory: state, smokeSeconds: smoke, reportURL: report,
                             expanded: args.contains("--expanded"), floating: args.contains("--floating"), fixture: fixture)
    }
}

@MainActor
final class BridgeRunner {
    var onSnapshot: ((LiveSnapshot) -> Void)?
    var onDisconnect: (() -> Void)?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var pending = Data()
    private var stopping = false
    private var generation = 0
    private(set) var childStarted = false
    private(set) var childStopped = true
    private(set) var snapshotCount = 0
    private(set) var malformedCount = 0
    private let limit = 8 * 1024 * 1024

    func start(maximumSeconds: Double? = nil) {
        guard process?.isRunning != true else { return }
        generation &+= 1
        let token = generation
        stopping = false
        pending.removeAll(keepingCapacity: false)
        guard let resources = Bundle.main.resourceURL else { onDisconnect?(); return }
        let executable = resources.appendingPathComponent("node")
        let program = resources.appendingPathComponent("bridge.mjs")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: program.path) else { onDisconnect?(); return }
        let child = Process()
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        child.executableURL = executable
        var arguments = ["--no-warnings", program.path, "--parent-pid", String(getpid())]
        if let seconds = maximumSeconds { arguments += ["--duration-seconds", String(Int(ceil(seconds)))] }
        child.arguments = arguments
        let allowed = Set(["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL",
                           "CODEX_HOME", "CLAUDE_CONFIG_DIR", "MONITOR_CLAUDE_HOOKS_DIR"])
        child.environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        child.environment?["PATH"] = "/usr/bin:/bin"
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = FileHandle.nullDevice
        input = stdinPipe
        output = stdoutPipe
        process = child
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.consume(bytes)
            }
        }
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.childStopped = true
                if !self.stopping { self.onDisconnect?() }
            }
        }
        do {
            try child.run()
            childStarted = true
            childStopped = false
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            process = nil
            input = nil
            output = nil
            childStopped = true
            onDisconnect?()
        }
    }

    private func consume(_ bytes: Data) {
        guard !stopping else { return }
        guard !bytes.isEmpty else {
            output?.fileHandleForReading.readabilityHandler = nil
            onDisconnect?()
            return
        }
        guard bytes.count <= limit, pending.count <= limit - bytes.count else {
            malformedCount += 1
            stop()
            onDisconnect?()
            return
        }
        pending.append(bytes)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if line.isEmpty { continue }
            if let snapshot = try? JSONDecoder().decode(LiveSnapshot.self, from: line),
               snapshot.type == "snapshot", snapshot.version == 1 {
                snapshotCount += 1
                onSnapshot?(snapshot)
            } else {
                malformedCount += 1
                onDisconnect?()
                if malformedCount >= 3 { stop(); return }
            }
        }
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        generation &+= 1
        try? input?.fileHandleForWriting.close()
        input = nil
        if let child = process, child.isRunning {
            child.terminate()
            let until = Date().addingTimeInterval(1)
            while child.isRunning && Date() < until { usleep(20_000) }
            if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        output?.fileHandleForReading.readabilityHandler = nil
        try? output?.fileHandleForReading.close()
        output = nil
        pending.removeAll(keepingCapacity: false)
        childStopped = process?.isRunning != true
        process = nil
    }

    func diagnostics() -> [String: Any] {
        ["childStarted": childStarted, "childStopped": childStopped,
         "snapshotCount": snapshotCount, "malformedMessages": malformedCount]
    }
}

struct ScreenMetrics {
    let frame: NSRect
    let visibleFrame: NSRect
    let safeTop: CGFloat
    let housingWidth: CGFloat
    /// Horizontal centre of the camera housing.
    let housingMidX: CGFloat
    var hasNotch: Bool { safeTop > 0 && housingWidth > 0 }

    @MainActor init(screen: NSScreen) {
        frame = screen.frame
        visibleFrame = screen.visibleFrame
        safeTop = screen.safeAreaInsets.top
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            housingWidth = max(0, right.minX - left.maxX)
            housingMidX = housingWidth > 0 ? (left.maxX + right.minX) / 2 : screen.frame.midX
        } else { housingWidth = 0; housingMidX = screen.frame.midX }
    }
    init(frame: NSRect, visibleFrame: NSRect, safeTop: CGFloat, housingWidth: CGFloat, housingMidX: CGFloat? = nil) {
        self.frame = frame; self.visibleFrame = visibleFrame
        self.safeTop = safeTop; self.housingWidth = housingWidth
        self.housingMidX = housingMidX ?? frame.midX
    }
}

enum PanelLayout {
    /// Island layout: the tabs sit in ears beside the camera housing, at its height.
    /// Running alone on the left, Input and Review on the right.
    static let leftEarWidth: CGFloat = 52
    static let rightEarWidth: CGFloat = 88
    /// Height of the tab bar above the task list. In the island the ears hold the tabs instead.
    static func barHeight(island: Bool) -> CGFloat { island ? 0 : 34 }

    /// `floatingAnchor` is the panel's top centre, so the compact and open panel share
    /// one centre line and whatever the user lined up stays lined up as it opens and closes.
    static func frame(metrics: ScreenMetrics, expanded: Bool, forceFloating: Bool,
                      floatingAnchor: NSPoint? = nil, expandedHeight: CGFloat = 272) -> NSRect {
        let notched = metrics.hasNotch && !forceFloating
        let available = notched ? metrics.frame : metrics.visibleFrame
        let island = metrics.housingWidth + leftEarWidth + rightEarWidth
        let desiredWidth = notched ? (expanded ? max(440, island) : island) : expanded ? 440 : 216
        let width = min(desiredWidth, max(0, available.width - 24))
        // `expandedHeight` counts a 34pt tab bar; the task list is the rest.
        let list = min(272, max(148, expandedHeight)) - 34
        let height = min((notched ? metrics.safeTop : 0) + barHeight(island: notched) + (expanded ? list : 0),
                         max(0, available.height - 24))
        if notched {
            // Compact, the ears fit their tabs; open, the list hangs centred under the housing.
            let housingMinX = metrics.housingMidX - metrics.housingWidth / 2
            let preferredX = expanded ? metrics.housingMidX - width / 2 : housingMinX - leftEarWidth
            let x = min(max(preferredX, available.minX), available.maxX - width)
            return NSRect(x: x, y: available.maxY - height, width: width, height: height)
        }
        let anchor = floatingAnchor ?? NSPoint(x: available.midX, y: available.maxY - 12)
        let x = min(max(anchor.x - width / 2, available.minX + 12), available.maxX - width - 12)
        let top = min(max(anchor.y, available.minY + height + 12), available.maxY - 12)
        return NSRect(x: x, y: top - height, width: width, height: height)
    }

    enum Drop: Equatable { case dock, float(NSPoint) }
    /// Where a floating panel goes when the user lets go of it. Pushed up into the menu
    /// bar over the camera housing, it docks into the island. Near the screen's centre
    /// line, it sits exactly on it. Otherwise it stays where it was dropped.
    static func drop(frame: NSRect, metrics: ScreenMetrics) -> Drop {
        let offset = frame.midX - metrics.housingMidX
        let reach = metrics.housingWidth / 2 + (offset < 0 ? leftEarWidth : rightEarWidth)
        if metrics.hasNotch && frame.maxY >= metrics.visibleFrame.maxY - 6 && abs(offset) <= reach {
            return .dock
        }
        let centre = metrics.visibleFrame.midX
        return .float(NSPoint(x: abs(frame.midX - centre) <= 24 ? centre : frame.midX, y: frame.maxY))
    }
}

/// Gives its one child a fraction of the child's natural width, so a label opens
/// out with the widening bar instead of popping into the row.
struct RevealWidth: Layout {
    var fraction: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(.unspecified)
        return CGSize(width: natural.width * min(1, max(0, fraction)), height: natural.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
    }
}

struct IslandShape: Shape {
    let attached: Bool
    /// 0 compact capsule, 1 open panel.
    var reveal: Double = 0
    func path(in rect: CGRect) -> Path {
        guard attached else { return Path(roundedRect: rect, cornerRadius: CGFloat(PanelReveal.cornerRadius(reveal))) }
        // Hangs from the top edge: square top, rounded bottom. Tighter while it is
        // only the strip beside the camera housing.
        let radius = min(rect.height / 2, CGFloat(12 + 6 * min(1, max(0, reveal))))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

@MainActor
func validatedSourceURL(_ text: String?) -> URL? {
    // One validation authority for both ingested task destinations and buttons.
    LiveModel.validatedSourceURL(text)
}

extension LiveState {
    var caption: String {
        switch self {
        case .running: return "Running"
        case .input: return "Needs input"
        case .review: return "Ready for review"
        case .read: return "Read in source app"
        case .idle: return "Idle, review unknown"
        case .error: return "Needs attention"
        case .unknown: return "Status unknown"
        }
    }
    var symbol: String {
        switch self {
        case .running: return "play.fill"
        case .input: return "pause.fill"
        case .review: return "tray.full.fill"
        case .read: return "circle"
        case .idle: return "circle.dashed"
        case .error: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.square"
        }
    }
    var color: Color {
        switch self {
        case .running: return Color(red: 0.48, green: 0.68, blue: 1)
        case .input: return Color(red: 1, green: 0.76, blue: 0.38)
        case .review: return Color(red: 0.76, green: 0.69, blue: 1)
        case .error: return Color(red: 1, green: 0.70, blue: 0.42)
        case .read, .idle, .unknown: return Color(white: 0.65)
        }
    }
}

/// The Running, Input and Review tabs' frames, so hovering one can select it.
struct SummaryTabFrames: PreferenceKey {
    static var defaultValue: [TaskSection: CGRect] { [:] }
    static func reduce(value: inout [TaskSection: CGRect], nextValue: () -> [TaskSection: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct TaskIslandView: View {
    @ObservedObject var model: LiveModel
    let synthetic: Bool
    let quit: () -> Void
    @State private var showUnavailable = false
    @State private var failedOpenTask: LiveTask?
    @State private var hoveredSection: TaskSection?

    private func sourceColor(_ provider: String) -> Color {
        provider == "codex" ? Color(red: 0.43, green: 0.67, blue: 1) : Color(red: 0.94, green: 0.57, blue: 0.36)
    }
    private func sourceBadge(_ provider: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(sourceColor(provider)).frame(width: 4, height: 4)
            Text(providerName(provider)).font(.system(size: 10, weight: .medium)).foregroundStyle(sourceColor(provider))
        }
    }

    private func open(_ task: LiveTask) {
        guard let url = validatedSourceURL(task.sourceURL) else { return }
        failedOpenTask = nil
        let generation = model.beginNavigation(task)
        if synthetic { model.finishNavigation(success: true, synthetic: true, generation: generation); return }
        let bundleID = task.provider == "codex" ? "com.openai.codex" : "com.anthropic.claudefordesktop"
        // Select the running distribution explicitly: older Codex and current
        // ChatGPT can share a bundle ID and scheme registration on one Mac.
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated && $0.bundleURL != nil }),
              let applicationURL = app.bundleURL else {
            model.finishNavigation(success: false, generation: generation); failedOpenTask = task; return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                let accepted = model.finishNavigation(success: error == nil, generation: generation)
                if accepted && error != nil { failedOpenTask = task }
                if accepted && error == nil { model.expanded = false }
            }
        }
    }
    private func copyTitle(_ task: LiveTask) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(task.title, forType: .string)
    }
    private func providerName(_ text: String) -> String { text == "codex" ? "Codex" : "Claude" }
    private func cacheCaption(_ task: LiveTask) -> String {
        let age = model.observationAgeSeconds(task)
        guard age >= 0 else { return "Cache · observation time unknown" }
        let suffix = model.cacheObservationExpired(task) ? " · expired" : model.displayState(task) == .unknown ? " · runtime unknown" : ""
        return "Catalog updated \(age)s ago\(suffix)"
    }
    private func unavailableCaption(_ task: LiveTask) -> String {
        switch task.availabilityReason {
        case "catalog-only": return "Catalog only · no live status"
        case "source-offline": return "Source app disconnected"
        case "stale-cache": return "Status observation expired"
        case "remote-disconnected": return "Remote session disconnected"
        case "metadata-only": return "Catalog information only"
        case "turn-record-only": return "Completion tracked · runtime unknown"
        default: return "No live status yet"
        }
    }
    private func healthCaption(_ health: String) -> String {
        switch health {
        case "live": return "Connected"
        case "degraded": return "Partial coverage"
        case "connecting": return "Connecting"
        default: return "Offline"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isIsland {
                islandStrip.frame(height: model.safeTop)
            } else {
                if model.safeTop > 0 { Color.clear.frame(height: model.safeTop).accessibilityHidden(true) }
                summary.frame(height: 34)
            }
            if model.expanded || model.reveal > 0.001 {
                // While the frame is moving the body keeps its final size and its final
                // place on screen and is uncovered by the growing panel, so its text never
                // reflows or slides along. At rest there is no motion and it fills the space.
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
                            expandedContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                        .frame(width: model.revealMotion?.bodyWidth, height: model.revealMotion?.bodyHeight, alignment: .topLeading)
                        .opacity(PanelReveal.bodyOpacity(model.reveal))
                        .offset(x: model.revealMotion?.bodyShift ?? 0, y: CGFloat(PanelReveal.bodyOffset(model.reveal)))
                    }
                    .clipped()
                    .allowsHitTesting(model.expanded)
            }
        }
        .foregroundStyle(Color.white)
        // Docked, it is black like the camera housing it grows out of.
        .background(model.isIsland ? Color.black : Color(white: 0.065))
        .clipShape(IslandShape(attached: model.safeTop > 0, reveal: model.reveal))
        .overlay {
            IslandShape(attached: model.safeTop > 0, reveal: model.reveal)
                .stroke(Color.white.opacity(model.isIsland ? 0.10 * model.reveal : 0.10), lineWidth: 0.5)
        }
        .preferredColorScheme(.dark)
        // Tabs live in the floating bar or the island's ears; either reports here.
        .onPreferenceChange(SummaryTabFrames.self) { [model] frames in
            MainActor.assumeIsolated { model.tabFrames = frames }
        }
    }

    private var summary: some View {
        // Labels open out, and the compact dividers fade, as the bar widens.
        let labels = PanelReveal.labelAmount(model.reveal)
        return HStack(spacing: 4) {
            countButton(.running, label: "Running", color: LiveState.running.color, symbol: "play.fill", labels: labels)
            if labels < 0.999 { summaryDivider.opacity(1 - labels) }
            countButton(.input, label: "Input", color: LiveState.input.color, symbol: "pause.fill", labels: labels)
            if labels < 0.999 { summaryDivider.opacity(1 - labels) }
            countButton(.review, label: "Review", color: LiveState.review.color, symbol: "tray.full.fill", labels: labels)
            Button { model.expanded.toggle() } label: {
                Image(systemName: model.isStale ? "exclamationmark.circle" : "chevron.down")
                    .rotationEffect(.degrees(model.isStale ? 0 : 180 * model.reveal))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(width: 24, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(model.expanded ? "Collapse panel" : "Expand tasks")
                .accessibilityHint(model.connectionLabel)
                .help(model.isStale ? "Disconnected · show tasks" : model.expanded ? "Collapse panel" : "Expand tasks")
        }.padding(.horizontal, 8)
    }

    /// Docked: Running in the ear left of the camera housing, Input and Review in the
    /// ear to its right. The housing itself stays empty inside the same black shape.
    /// Icons and counts only; the open panel's header names the selected tab.
    private var islandStrip: some View {
        HStack(spacing: 0) {
            countButton(.running, label: "Running", color: LiveState.running.color, symbol: "play.fill", labels: 0, emphasis: model.reveal)
                .padding(.leading, 6).frame(width: max(0, model.notchLeading))
                // A badge, not a sibling: the narrow ear keeps its whole width for the count.
                .overlay(alignment: .topLeading) {
                    if model.isStale {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.6)).padding(.leading, 4).padding(.top, 3)
                            .accessibilityLabel("Disconnected").help("Disconnected")
                    }
                }
            Color.clear.frame(width: model.notchWidth).accessibilityHidden(true)
            HStack(spacing: 2) {
                countButton(.input, label: "Input", color: LiveState.input.color, symbol: "pause.fill", labels: 0, emphasis: model.reveal)
                countButton(.review, label: "Review", color: LiveState.review.color, symbol: "tray.full.fill", labels: 0, emphasis: model.reveal)
            }.padding(.trailing, 6).frame(maxWidth: .infinity)
        }
    }

    private var summaryDivider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 0.5, height: 12).accessibilityHidden(true)
    }

    /// `emphasis` is how strongly the selected tab is marked; it follows the labels in the
    /// floating bar and the opening panel in the island, where there are no labels.
    private func countButton(_ section: TaskSection, label: String, color: Color, symbol: String, labels: Double, emphasis: Double? = nil) -> some View {
        let count = model.count(section)
        // Last seen running, observation since expired: shown hollow, never counted as confirmed.
        let unconfirmed = section == .running ? model.unconfirmedRunningCount : 0
        let hollow = count == 0 && unconfirmed > 0
        let shown = hollow ? unconfirmed : count
        let selected = model.selection == section
        let highlight = max(selected ? 0.075 * (emphasis ?? labels) : 0, hoveredSection == section ? 0.04 : 0)
        let countDescription = "\(label): \(count) \(count == 1 ? "task" : "tasks")" +
            (unconfirmed > 0 ? " · \(unconfirmed) last seen running, awaiting sync" : "")
        return Button { model.selection = section; model.expanded = true } label: {
            HStack(spacing: 6) {
                Image(systemName: hollow ? "play" : symbol).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(count > 0 ? color : hollow ? color.opacity(0.8) : Color.white.opacity(0.36))
                    .frame(width: 13)
                if labels > 0.001 {
                    RevealWidth(fraction: CGFloat(labels)) {
                        Text(label).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(selected ? 0.90 : 0.60))
                            .lineLimit(1).fixedSize()
                    }.clipped().opacity(labels)
                }
                Text(shown > 99 ? "99+" : "\(shown)")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Color.white.opacity(count > 0 ? 0.92 : hollow ? 0.72 : 0.48))
                    .lineLimit(1).fixedSize()
            }.frame(maxWidth: .infinity, minHeight: 26)
                .background(Color.white.opacity(highlight), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(countDescription)
            .help(countDescription)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: SummaryTabFrames.self, value: [section: proxy.frame(in: .global)])
            })
            .onHover { hovering in
                if hovering { hoveredSection = section }
                else if hoveredSection == section { hoveredSection = nil }
            }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.selection == .input ? "Needs input" : model.selection.rawValue)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white.opacity(0.88))
                if synthetic {
                    Text("Preview").font(.system(size: 9, weight: .medium)).foregroundStyle(Color.orange.opacity(0.75))
                }
                Spacer()
                if model.selection != .all {
                    Button { model.selection = .all } label: {
                        Image(systemName: "list.bullet").font(.system(size: 11, weight: .medium))
                            .frame(width: 24, height: 22).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.55))
                        .accessibilityLabel("All tasks").help("All tasks")
                }
            }
            if let error = model.ledgerError {
                Text(error).font(.system(size: 11)).foregroundStyle(LiveState.error.color).lineLimit(2)
            }
            if model.selection == .review { reviewContent } else { taskList }
            if let failed = failedOpenTask {
                HStack {
                    Text("Couldn't open task").font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.6))
                    Button("Copy title") { copyTitle(failed) }.font(.system(size: 10)).buttonStyle(.plain)
                }
            }
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var reviewContent: some View {
        if model.pendingReviewGroups.isEmpty {
            Text("No tasks to review").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.pendingReviewGroups) { group in
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.task.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                HStack(spacing: 7) {
                                    sourceBadge(group.task.provider)
                                    if group.items.count > 1 {
                                        Text("\(group.items.count) updates").font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.45))
                                    }
                                    if !model.canMarkReviewed(group) {
                                        Text("Unconfirmed result").font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.45))
                                    } else if group.task.completionTracking == "observed-change" {
                                        Text("Inferred completion").font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.45))
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button { open(group.task) } label: {
                                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                                    .frame(width: 28, height: 28).contentShape(Rectangle())
                            }.buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.7))
                                .disabled(validatedSourceURL(group.task.sourceURL) == nil)
                                .accessibilityLabel("Open task: \(group.task.title)")
                                .help("Open in \(providerName(group.task.provider))")
                            Button { model.markReviewed(group) } label: {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                                    .frame(width: 28, height: 28)
                                    .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain).disabled(!model.canMarkReviewed(group))
                                .accessibilityLabel("Mark reviewed: \(group.task.title)")
                                .help("Mark reviewed")
                        }.padding(.vertical, 8)
                            .contextMenu { Button("Copy task title") { copyTitle(group.task) } }
                        if group.id != model.pendingReviewGroups.last?.id {
                            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
        }
    }

    private var listedTasks: [LiveTask] {
        let values = model.tasks.filter {
            switch model.selection {
            case .running: return model.displayState($0) == .running
            case .input: return model.displayState($0) == .input
            case .all, .review: return true
            }
        }
        return values.sorted {
            let a = model.displayState($0) != .unknown, b = model.displayState($1) != .unknown
            return a != b ? a : $0.updatedAt > $1.updatedAt
        }
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                let available = listedTasks.filter { model.displayState($0) != .unknown }
                let unavailable = listedTasks.filter { model.displayState($0) == .unknown }
                if available.isEmpty && (!([.running, .all].contains(model.selection)) || model.recentActivity.isEmpty) {
                    Text(model.isStale ? "Waiting to reconnect" : model.selection == .running ? "No confirmed running tasks" : model.selection == .input ? "No tasks need input" : "No confirmed task status")
                        .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.65)).padding(.vertical, 12)
                }
                ForEach(available) { task in taskRow(task) }
                if [.running, .all].contains(model.selection) && !model.recentActivity.isEmpty {
                    Text("Awaiting sync").font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.4))
                    ForEach(model.recentActivity) { task in recentTaskRow(task) }
                }
                if model.selection == .all && !unavailable.isEmpty {
                    Button { showUnavailable.toggle() } label: {
                        HStack {
                            Image(systemName: showUnavailable ? "chevron.down" : "chevron.right")
                            Text("Status unavailable (\(unavailable.count))")
                            Spacer()
                        }.font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.55))
                            .frame(minHeight: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if showUnavailable {
                        Text("Live status is unavailable. Queued reviews are retained.")
                            .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.55))
                        ForEach(unavailable.filter { !model.recentActivity.contains($0) }) { task in taskRow(task) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: .infinity)
    }

    private func taskRow(_ task: LiveTask) -> some View {
        let state = model.displayState(task)
        let reviewed = [.review, .read, .error].contains(state) && model.isResultReviewed(task)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                HStack(spacing: 7) {
                    sourceBadge(task.provider)
                    Image(systemName: reviewed ? "checkmark.circle" : state.symbol).font(.system(size: 8)).foregroundStyle(state.color)
                    Text(reviewed ? state == .error ? "Error · reviewed" : "Result reviewed" : state == .unknown ? unavailableCaption(task) : task.provider == "claude" && state == .read ? "Opened (inferred)" : state.caption)
                        .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.60))
                }
            }
            Spacer(minLength: 0)
            Button { open(task) } label: {
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.65))
                .disabled(validatedSourceURL(task.sourceURL) == nil)
                .accessibilityLabel("Open task: \(task.title)").help("Open in \(providerName(task.provider))")
        }
    }

    private func recentTaskRow(_ task: LiveTask) -> some View {
        let age = model.observationAgeSeconds(task)
        let time = age < 60 ? "\(max(0, age))s ago" : "\(age / 60)m ago"
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                HStack(spacing: 7) {
                    sourceBadge(task.provider)
                    Text("Last \(task.lastObservedState == .running ? "running" : "input needed") · \(time)")
                        .font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.5))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { open(task) } label: {
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.7))
                .disabled(validatedSourceURL(task.sourceURL) == nil)
                .accessibilityLabel("Open task: \(task.title)").help("Open in \(providerName(task.provider))")
        }.padding(.vertical, 5)
    }
}

final class IslandPanel: NSPanel {
    var escape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { escape?() }
}

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var onPointerChange: ((Bool) -> Void)?
    /// Real pointer movement inside the panel, in screen coordinates.
    var onPointerMove: ((NSPoint) -> Void)?
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
        reconcilePointer()
    }

    func containsScreenPoint(_ point: NSPoint) -> Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.convertPoint(fromScreen: point), from: nil))
    }

    func reconcilePointer() {
        onPointerChange?(window?.isVisible == true && containsScreenPoint(pointerLocation()))
    }

    /// A rect in SwiftUI's global space for this view (top-left origin) on screen.
    func screenRect(fromSwiftUI rect: CGRect) -> CGRect? {
        guard let window else { return nil }
        let local = isFlipped ? rect : CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        return window.convertToScreen(convert(local, to: nil))
    }

    private func reportPointerMove() {
        let point = pointerLocation()
        if window?.isVisible == true && containsScreenPoint(point) { onPointerMove?(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        reportPointerMove()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        reconcilePointer()
        // No move is reported here: resizing generates entries under a still pointer,
        // and only real movement may select a tab.
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // Resizing replaces tracking areas; trust the actual pointer position,
        // not a synthetic exit from the old compact bounds.
        reconcilePointer()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    let model: LiveModel
    let bridge = BridgeRunner()
    private let sounds = SoundEffects()
    private var applyingHoverExpansion = false
    private lazy var hover = HoverExpansionController(isExpanded: model.expanded, onChange: { [weak self] expanded in
        guard let self, self.panel?.isVisible == true else { return }
        if self.model.expanded != expanded {
            self.applyingHoverExpansion = true
            self.model.expanded = expanded
            self.applyingHoverExpansion = false
        }
    })
    // Hovering Running, Input or Review selects it; a click still does too.
    private lazy var tabHover = HoverTabSelector<TaskSection>(onSelect: { [weak self] section in
        guard let self, self.panel?.isVisible == true, self.trackingMenus == 0, !self.model.navigationPending,
              self.model.selection != section else { return }
        self.model.selection = section
    })
    private var pointerView: IslandHostingView<TaskIslandView>?
    private var trackingMenus = 0
    // Frame motion. Present only while the panel is moving between sizes.
    private var motion: PanelMotion?
    private var motionTimer: Timer?
    private var motionClock: TimeInterval = 0
    private var panel: IslandPanel?
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var smokeTimer: Timer?
    private var forceFloating: Bool
    /// Top centre of the floating panel once the user has moved it.
    private var floatingAnchor: NSPoint?
    /// Present while the window server drags the floating panel.
    private var dragTimer: Timer?
    /// Dragging the docked island off the housing; the app moves the panel itself.
    private var dockedDrag = DockedDrag()
    private var dockedPoll: Timer?
    private var followingPointer = false
    private var mouseMonitor: Any?
    private var housingMinX: CGFloat = 0
    private var isDragging: Bool { dragTimer != nil || followingPointer }
    private var placementItem: NSMenuItem?
    private var relocating = false
    private var finalReportWritten = false
    private var instanceLock: Int32 = -1
    private var statusTicks = 0
    private var reopenCount = 0

    init(options: LaunchOptions) {
        self.options = options
        model = LiveModel(stateDirectory: options.stateDirectory, persist: options.fixture == nil)
        forceFloating = options.floating || !UserDefaults.standard.bool(forKey: "attachToNotch")
        super.init()
        model.expanded = options.expanded
        if options.fixture == nil { model.selection = model.pendingReviewGroups.isEmpty ? .running : .review }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if options.fixture == nil {
            let lockPath = options.stateDirectory.appendingPathComponent("instance.lock").path
            instanceLock = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
                NSApplication.shared.terminate(nil); return
            }
        }
        let p = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel = p
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.animationBehavior = .none; p.title = options.fixture == nil ? "Monita" : "Monita Test"
        p.escape = { [weak self] in self?.model.expanded = false }
        let hosting = IslandHostingView(rootView: TaskIslandView(model: model, synthetic: options.fixture != nil, quit: {
            NSApplication.shared.terminate(nil)
        }))
        hosting.onPointerChange = { [weak self] inside in
            self?.hover.pointerChanged(isInside: inside)
            if !inside { self?.tabHover.pointerLeft() }
        }
        hosting.onPointerMove = { [weak self] point in self?.pointerMoved(to: point) }
        pointerView = hosting
        p.contentView = hosting
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.title = "◉ Connecting"
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Monita", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(withTitle: "Hide Monita", action: #selector(hidePanel), keyEquivalent: "")
        let placementItem = menu.addItem(withTitle: "Movable Panel", action: #selector(toggleFloating(_:)), keyEquivalent: "")
        placementItem.state = forceFloating ? .on : .off
        self.placementItem = placementItem
        let soundItem = menu.addItem(withTitle: "Sound Effects", action: #selector(toggleSounds(_:)), keyEquivalent: "")
        soundItem.state = sounds.isEnabled ? .on : .off
        menu.addItem(withTitle: "Reconnect", action: #selector(reconnect), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Monita", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }
        item.menu = menu
        model.$expanded.dropFirst().sink { [weak self] expanded in
            let fromHover = self?.applyingHoverExpansion ?? false
            // This runs before the value changes. Pin the content where it is now, so
            // it does not jump to its end state a frame before the frame starts moving.
            self?.holdReveal(becoming: expanded)
            DispatchQueue.main.async { [weak self] in
                if !fromHover { self?.hover.expansionChanged(expanded) }
                self?.relayout(animated: true)
            }
        }.store(in: &subscriptions)
        model.$selection.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.relayout(animated: true) }
        }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(panelMoved),
                                               name: NSWindow.didMoveNotification, object: p)
        NotificationCenter.default.addObserver(self, selector: #selector(panelWillMove),
                                               name: NSWindow.willMoveNotification, object: p)
        // A docked panel cannot be moved by its background; dragging it off is handled here.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            let number = event.windowNumber
            MainActor.assumeIsolated { self?.islandPressed(windowNumber: number) }
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingBegan),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingEnded),
                                               name: NSMenu.didEndTrackingNotification, object: nil)
        bridge.onSnapshot = { [weak self] snapshot in self?.model.apply(snapshot) }
        bridge.onDisconnect = { [weak self] in self?.model.disconnected() }
        if options.fixture == nil {
            model.onAttentionEvent = { [weak self] event in self?.sounds.handle(event) }
        }
        relayout()
        p.orderFrontRegardless()
        hosting.reconcilePointer()
        if let fixture = options.fixture { UIFixture.apply(fixture, to: model) }
        else { bridge.start(maximumSeconds: options.smokeSeconds.map { $0 + 5 }) }
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.options.fixture == nil { self.model.tick() }
                self.statusItem?.button?.title = "◉ \(self.model.count(.running)) · \(self.model.count(.input)) · \(self.model.count(.review))"
                self.statusItem?.button?.toolTip = nil
                if self.model.expanded, let panel = self.panel, let open = self.targetFrame(expanded: true),
                   abs(panel.frame.height - open.height) > 0.5 { self.relayout(animated: true) }
                self.statusTicks += 1
                if self.statusTicks % 5 == 0 { self.writeAggregateStatus() }
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        if let seconds = options.smokeSeconds {
            smokeTimer = Timer(timeInterval: seconds, repeats: false) { _ in
                MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
            }
            if let smokeTimer { RunLoop.main.add(smokeTimer, forMode: .common) }
        }
    }

    private func targetScreen() -> NSScreen? {
        if !forceFloating, let screen = NSScreen.screens.first(where: { ScreenMetrics(screen: $0).hasNotch }) { return screen }
        return panel?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }
    private func targetFrame(expanded: Bool) -> NSRect? {
        guard let screen = targetScreen() else { return nil }
        return PanelLayout.frame(metrics: ScreenMetrics(screen: screen), expanded: expanded, forceFloating: forceFloating,
                                 floatingAnchor: floatingAnchor, expandedHeight: model.preferredPanelHeight)
    }
    /// Motion is skipped when the panel is hidden or the system asks for less of it.
    private var motionAllowed: Bool {
        panel?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    /// The body's final size and resting place, seen from a panel whose left edge is at `panelX`.
    private func revealMotion(progress: Double, panelX: Double) -> RevealMotion? {
        guard let open = targetFrame(expanded: true) else { return nil }
        return RevealMotion(progress: progress,
                            bodyWidth: open.width, bodyHeight: max(0, open.height - PanelLayout.barHeight(island: model.isIsland) - model.safeTop),
                            bodyShift: open.minX - CGFloat(panelX))
    }
    private func holdReveal(becoming expanded: Bool) {
        guard motionAllowed, model.expanded != expanded, model.revealMotion == nil, let panel else { return }
        model.revealMotion = revealMotion(progress: model.expanded ? 1 : 0, panelX: Double(panel.frame.minX))
    }
    private func relayout(animated: Bool = false) {
        // The user is placing the panel; it is laid out again when they let go.
        guard !isDragging, let panel, let screen = targetScreen() else { return }
        let metrics = ScreenMetrics(screen: screen)
        let notched = metrics.hasNotch && !forceFloating
        model.safeTop = notched ? metrics.safeTop : 0
        model.notchWidth = notched ? metrics.housingWidth : 0
        housingMinX = metrics.housingMidX - metrics.housingWidth / 2
        panel.isMovableByWindowBackground = !notched
        let target = PanelLayout.frame(metrics: metrics, expanded: model.expanded, forceFloating: forceFloating,
                                       floatingAnchor: floatingAnchor, expandedHeight: model.preferredPanelHeight)
        let pending = motion != nil || model.revealMotion != nil || panel.frame != target
        guard animated, motionAllowed, pending else { settle(at: target); return }
        var current = motion ?? PanelMotion(
            frame: PanelMotion.Frame(x: Double(panel.frame.minX), top: Double(panel.frame.maxY),
                                     width: Double(panel.frame.width), height: Double(panel.frame.height)),
            reveal: model.revealMotion?.progress ?? (model.expanded ? 1 : 0))
        current.retarget(PanelMotion.Frame(x: Double(target.minX), top: Double(target.maxY),
                                           width: Double(target.width), height: Double(target.height)),
                         reveal: model.expanded ? 1 : 0)
        motion = current
        model.revealMotion = revealMotion(progress: current.reveal, panelX: current.frame.x)
        guard motionTimer == nil else { return }
        motionClock = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepMotion() }
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }
    private func stepMotion() {
        guard var current = motion else { settle(at: nil); return }
        let now = ProcessInfo.processInfo.systemUptime
        current.step(dt: now - motionClock)
        motionClock = now
        if current.isSettled || !motionAllowed {
            let end = current.target
            settle(at: NSRect(x: end.x, y: end.top - end.height, width: end.width, height: end.height))
            return
        }
        motion = current
        let frame = current.frame
        model.revealMotion = revealMotion(progress: current.reveal, panelX: frame.x)
        place(NSRect(x: frame.x, y: frame.top - frame.height, width: frame.width, height: frame.height))
    }
    /// Ends any motion and puts the panel exactly at its resting frame.
    private func settle(at target: NSRect?) {
        motionTimer?.invalidate()
        motionTimer = nil
        motion = nil
        if let target { place(target) }
        if model.revealMotion != nil { model.revealMotion = nil }
        panel?.invalidateShadow()
        pointerView?.reconcilePointer()
    }
    private func place(_ frame: NSRect) {
        let leading = model.isIsland ? housingMinX - frame.minX : 0
        if model.notchLeading != leading { model.notchLeading = leading }
        guard let panel, panel.frame != frame else { return }
        relocating = true
        panel.setFrame(frame, display: true)
        relocating = false
    }
    @objc private func screensChanged() { floatingAnchor = nil; relayout() }
    @objc private func panelMoved() {
        guard !relocating, model.safeTop == 0, let panel else { return }
        floatingAnchor = NSPoint(x: panel.frame.midX, y: panel.frame.maxY)
        beginDragIfPressed()
    }
    @objc private func panelWillMove() {
        guard !relocating, model.safeTop == 0 else { return }
        beginDragIfPressed()
    }
    /// While the user drags the panel it neither opens nor closes under the pointer and
    /// tab hover is off. The window server moves the window and may not deliver the
    /// mouse-up, so the button is polled until it is released.
    private func beginDragIfPressed() {
        guard dragTimer == nil, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        // Stop any open/close motion where it is, without moving the window the server
        // is dragging; it is laid out properly when the user lets go.
        if motion != nil { settle(at: nil) }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if NSEvent.pressedMouseButtons & 1 == 0 { self?.endDrag() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
        hover.setInteractionActive(true)
        tabHover.pointerLeft()
    }
    private func endDrag() {
        dragTimer?.invalidate()
        dragTimer = nil
        applyDrop()
    }
    /// Docks over the housing, centres near the centre line, or stays where it was let go.
    private func applyDrop() {
        if let panel, model.safeTop == 0, let screen = panel.screen ?? targetScreen() {
            switch PanelLayout.drop(frame: panel.frame, metrics: ScreenMetrics(screen: screen)) {
            case .dock: setFloating(false)
            case .float(let anchor): floatingAnchor = anchor; relayout(animated: true)
            }
        }
        pointerView?.reconcilePointer()
        tabHover.pointerSettled(at: NSEvent.mouseLocation)
        hover.setInteractionActive(isDragging || trackingMenus > 0)
    }
    private var pointer: DockedDrag.Point {
        let location = NSEvent.mouseLocation
        return DockedDrag.Point(x: Double(location.x), y: Double(location.y))
    }
    /// A press on the docked island. Its drag events may be consumed by a control's
    /// own tracking loop, which event monitors never see, so from here the pointer and
    /// button are polled instead; timers in common mode also run during tracking.
    private func islandPressed(windowNumber: Int) {
        guard let panel, windowNumber == panel.windowNumber, model.isIsland, !isDragging, dockedPoll == nil,
              // Only the ears beside the housing; presses in the open list are for its rows.
              NSEvent.mouseLocation.y >= panel.frame.maxY - model.safeTop else { return }
        _ = dockedDrag.pressed(at: pointer, docked: true)
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollDockedDrag() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dockedPoll = timer
    }
    private func pollDockedDrag() {
        let held = NSEvent.pressedMouseButtons & 1 != 0
        let step = held ? dockedDrag.dragged(to: pointer) : dockedDrag.released()
        if !held { dockedPoll?.invalidate(); dockedPoll = nil }
        switch step {
        case .pass: break
        case .undock(let anchor): undock(at: anchor)
        case .move(let anchor): follow(anchor)
        case .drop:
            followingPointer = false
            applyDrop()
        }
    }
    private func undock(at anchor: DockedDrag.Point) {
        // SwiftUI saw the mouse-down; release it far from every control so no tab fires.
        if let panel, let cancel = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10_000, y: -10_000),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
            pointerView?.mouseUp(with: cancel)
        }
        hover.setInteractionActive(true)
        tabHover.pointerLeft()
        // Drag the compact capsule, not the open list. Laid out synchronously here; the
        // expansion observer's own relayout comes later and is skipped while dragging.
        model.expanded = false
        setFloating(true, anchor: NSPoint(x: anchor.x, y: anchor.y))
        followingPointer = true
        follow(anchor)
    }
    /// Unclamped while following, so the panel can be pushed back up over the housing.
    private func follow(_ anchor: DockedDrag.Point) {
        guard let panel else { return }
        let frame = panel.frame
        floatingAnchor = NSPoint(x: anchor.x, y: anchor.y)
        place(NSRect(x: anchor.x - frame.width / 2, y: anchor.y - frame.height, width: frame.width, height: frame.height))
    }
    @objc private func showPanel() {
        hover.expansionChanged(model.expanded)
        relayout()
        panel?.orderFrontRegardless()
        pointerView?.reconcilePointer()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopenCount += 1
        model.expanded = true
        showPanel()
        writeAggregateStatus()
        return false
    }
    @objc private func hidePanel() {
        // Land any motion on its resting frame first, so the panel is not hidden mid-way.
        if let end = motion?.target {
            settle(at: NSRect(x: end.x, y: end.top - end.height, width: end.width, height: end.height))
        }
        hover.cancel()
        tabHover.pointerLeft()
        panel?.orderOut(nil)
    }
    /// Tab frames are measured against the panel as it is laid out now, on screen,
    /// so tabs sliding under a still pointer while the panel opens never count.
    private func pointerMoved(to point: NSPoint) {
        guard panel?.isVisible == true, trackingMenus == 0, !isDragging, let view = pointerView else { return }
        var tabs: [TaskSection: CGRect] = [:]
        for (section, rect) in model.tabFrames where section != .all {
            if let onScreen = view.screenRect(fromSwiftUI: rect) { tabs[section] = onScreen }
        }
        tabHover.pointerMoved(to: point, tabs: tabs)
    }
    @objc private func menuTrackingBegan() {
        trackingMenus += 1
        hover.setInteractionActive(true)
        tabHover.pointerLeft()
    }
    @objc private func menuTrackingEnded() {
        trackingMenus = max(0, trackingMenus - 1)
        if trackingMenus == 0 {
            pointerView?.reconcilePointer()
            hover.setInteractionActive(isDragging)
        }
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc private func toggleFloating(_ sender: NSMenuItem) { setFloating(!forceFloating) }
    /// Docked beside the camera housing, or a movable panel (at `anchor`, its top centre).
    private func setFloating(_ floating: Bool, anchor: NSPoint? = nil) {
        forceFloating = floating
        placementItem?.state = forceFloating ? .on : .off
        if options.fixture == nil { UserDefaults.standard.set(!forceFloating, forKey: "attachToNotch") }
        floatingAnchor = anchor; relayout()
    }
    @objc private func toggleSounds(_ sender: NSMenuItem) {
        guard options.fixture == nil else { return }
        sounds.setEnabled(!sounds.isEnabled)
        sender.state = sounds.isEnabled ? .on : .off
        writeAggregateStatus()
    }
    @objc private func reconnect() {
        guard options.fixture == nil else { return }
        bridge.stop()
        model.disconnected()
        bridge.start(maximumSeconds: options.smokeSeconds.map { $0 + 5 })
    }
    private func writeAggregateStatus() {
        guard options.fixture == nil, panel != nil, instanceLock >= 0 else { return }
        let path = options.stateDirectory.appendingPathComponent("runtime-status.json")
        let temporary = options.stateDirectory.appendingPathComponent(".runtime-status-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let report: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
            "generatedAt": LiveModel.milliseconds(), "snapshot": model.diagnostics(), "bridge": bridge.diagnostics(),
            "windowCount": panel?.isVisible == true ? 1 : 0,
            "expanded": model.expanded, "reopenCount": reopenCount, "soundEffectsEnabled": sounds.isEnabled,
            "hoverToExpandEnabled": true,
            "frame": ["width": panel?.frame.width ?? 0, "height": panel?.frame.height ?? 0],
            "providerCounts": Dictionary(uniqueKeysWithValues: TaskProvider.allCases.map { source in
                (source.rawValue, ["running": model.count(.running, provider: source), "input": model.count(.input, provider: source),
                                  "review": model.count(.review, provider: source), "catalog": model.count(.all, provider: source)])
            })]
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: path.path) {
                _ = try FileManager.default.replaceItemAt(path, withItemAt: temporary, options: .usingNewMetadataOnly)
            } else { try FileManager.default.moveItem(at: temporary, to: path) }
        } catch { /* Optional metadata counters; never log source content. */ }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); smokeTimer?.invalidate()
        motionTimer?.invalidate(); motionTimer = nil
        sounds.stop()
        hover.cancel()
        var report: [String: Any] = ["version": 1, "snapshot": model.diagnostics(),
                                   "windowShown": panel?.isVisible ?? false, "screenCount": NSScreen.screens.count,
                                   "visibleContentWindows": NSApplication.shared.windows.filter { $0.isVisible && $0 === panel }.count,
                                   "placement": NSScreen.screens.isEmpty ? "no_display" : model.safeTop > 0 ? "notch" : "floating"]
        if let frame = panel?.frame {
            report["frame"] = ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
        }
        bridge.stop()
        model.disconnected()
        report["bridge"] = bridge.diagnostics()
        if instanceLock >= 0 { _ = flock(instanceLock, LOCK_UN); Darwin.close(instanceLock); instanceLock = -1 }
        if let fixture = options.fixture { report["fixture"] = fixture }
        panel?.orderOut(nil)
        if let path = options.reportURL, !finalReportWritten {
            finalReportWritten = true
            do {
                let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try bytes.write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            } catch { /* Fixed aggregate reports are optional; never log task metadata. */ }
        }
    }
}

@MainActor
func runGeometryChecks() {
    let metrics = ScreenMetrics(frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
                                visibleFrame: NSRect(x: 0, y: 38, width: 1512, height: 906), safeTop: 32, housingWidth: 210)
    let other = ScreenMetrics(frame: NSRect(x: -1920, y: 100, width: 1920, height: 1080),
                              visibleFrame: NSRect(x: -1920, y: 140, width: 1920, height: 1012), safeTop: 0, housingWidth: 0)
    let small = ScreenMetrics(frame: NSRect(x: 1512, y: 0, width: 400, height: 360),
                              visibleFrame: NSRect(x: 1512, y: 20, width: 400, height: 300), safeTop: 0, housingWidth: 0)
    let floatingCollapsed = PanelLayout.frame(metrics: metrics, expanded: false, forceFloating: true)
    let floatingExpanded = PanelLayout.frame(metrics: metrics, expanded: true, forceFloating: true)
    assert(floatingCollapsed.size == NSSize(width: 216, height: 34))
    assert(floatingExpanded.size == NSSize(width: 440, height: 272))
    let single = PanelLayout.frame(metrics: metrics, expanded: true, forceFloating: true, expandedHeight: 148)
    assert(single.height == 148 && single.maxY == floatingExpanded.maxY)
    assert(floatingCollapsed.width * floatingCollapsed.height < 500 * 46 / 2,
           "Collapsed floating area is less than half of the earlier capsule")
    assert(floatingCollapsed.midX == metrics.visibleFrame.midX && floatingExpanded.midX == floatingCollapsed.midX,
           "Default floating placement stays centered as it expands")
    assert(floatingCollapsed.maxY == metrics.visibleFrame.maxY - 12 && floatingExpanded.maxY == floatingCollapsed.maxY)
    // Island: only the menu-bar strip when compact, a 52pt ear left of the housing for
    // Running and an 88pt ear right of it for Input and Review.
    let island = PanelLayout.frame(metrics: metrics, expanded: false, forceFloating: false)
    assert(island.size == NSSize(width: 52 + 210 + 88, height: metrics.safeTop) && island.minX == 756 - 105 - 52,
           "The compact island is the housing plus a narrow left ear and a wider right ear, no taller than the menu bar")
    let islandOpen = PanelLayout.frame(metrics: metrics, expanded: true, forceFloating: false)
    assert(islandOpen.size == NSSize(width: 440, height: metrics.safeTop + 272 - 34) && islandOpen.midX == 756,
           "Open, the list hangs centred under the housing; no separate tab bar")
    let offCentre = ScreenMetrics(frame: metrics.frame, visibleFrame: metrics.visibleFrame, safeTop: 32, housingWidth: 200, housingMidX: 760)
    assert(PanelLayout.frame(metrics: offCentre, expanded: false, forceFloating: false).minX == 760 - 100 - 52 &&
           PanelLayout.frame(metrics: offCentre, expanded: true, forceFloating: false).midX == 760,
           "The island follows the housing itself, not the screen centre")
    for expanded in [false, true] {
        let attached = PanelLayout.frame(metrics: metrics, expanded: expanded, forceFloating: false)
        assert(attached.maxY == metrics.frame.maxY && attached.minX <= 756 - 105 - 52 && attached.maxX >= 756 + 105 + 88)
        assert(attached.height >= metrics.safeTop)
        for value in [metrics, other, small] {
            let centered = PanelLayout.frame(metrics: value, expanded: expanded, forceFloating: true)
            assert(centered.midX == value.visibleFrame.midX && centered.maxY == value.visibleFrame.maxY - 12)
            assert(centered.width <= value.visibleFrame.width - 24 && centered.height <= value.visibleFrame.height - 24)
            for anchor in [nil, NSPoint(x: -5000, y: 5000), NSPoint(x: 5000, y: -5000)] {
                assert(value.visibleFrame.contains(PanelLayout.frame(metrics: value, expanded: expanded,
                                                                    forceFloating: true, floatingAnchor: anchor)))
            }
        }
        let manualAnchor = NSPoint(x: metrics.visibleFrame.minX + 400, y: metrics.visibleFrame.maxY - 40)
        let manuallyPlaced = PanelLayout.frame(metrics: metrics, expanded: expanded,
                                               forceFloating: true, floatingAnchor: manualAnchor)
        assert(manuallyPlaced.midX == manualAnchor.x && manuallyPlaced.maxY == manualAnchor.y,
               "A user-placed panel keeps its top centre, open or closed")
    }
    // Letting go of a dragged panel.
    let underBar = metrics.visibleFrame.maxY
    func dropped(midX: CGFloat, top: CGFloat, width: CGFloat = 216, on screen: ScreenMetrics = metrics) -> PanelLayout.Drop {
        PanelLayout.drop(frame: NSRect(x: midX - width / 2, y: top - 34, width: width, height: 34), metrics: screen)
    }
    assert(dropped(midX: 756, top: underBar + 10) == .dock, "Pushed into the menu bar over the housing, it docks")
    assert(dropped(midX: 756 + 105 + 88, top: underBar) == .dock, "An ear's width beside the housing still docks")
    assert(dropped(midX: 756 - 105 - 52, top: underBar) == .dock, "The left reach is the narrower left ear")
    assert(dropped(midX: 756 - 105 - 53, top: underBar) == .float(NSPoint(x: 756 - 105 - 53, y: underBar)),
           "Beyond the left ear it stays where it is")
    assert(dropped(midX: 756 + 105 + 89, top: underBar) == .float(NSPoint(x: 756 + 105 + 89, y: underBar)),
           "Further along the menu bar it stays where it is")
    assert(dropped(midX: 756, top: underBar - 12) == .float(NSPoint(x: 756, y: underBar - 12)),
           "The default spot under the menu bar does not dock")
    assert(dropped(midX: 770, top: 600) == .float(NSPoint(x: 756, y: 600)), "Within 24pt of the centre line it centres")
    assert(dropped(midX: 781, top: 600) == .float(NSPoint(x: 781, y: 600)), "Further off centre it stays put")
    assert(dropped(midX: -960, top: other.visibleFrame.maxY + 5, on: other) == .float(NSPoint(x: -960, y: other.visibleFrame.maxY + 5)),
           "A screen without a housing never docks")
    assert(validatedSourceURL("codex://threads/aaaaaa") != nil)
    assert(validatedSourceURL("codex://threads/aaaaaa?hostId=remote-machine:1") != nil)
    assert(validatedSourceURL("claude://code/continue?session=local_sample-1") != nil)
    assert(validatedSourceURL("claude://code/cse_remote-1") != nil)
    assert(validatedSourceURL("claude://code/session_remote_1") != nil)
    for url in ["https://example.com", "codex://threads/aaaaaa?run=x", "codex://other/aaaaaa",
                "codex://threads/aaaaaa?hostId=machine&hostId=other", "codex://threads/aaaaaa?hostId=machine&run=x",
                "codex://threads/aaaaaa?hostId=..%2Fmachine", "codex://user@threads/aaaaaa?hostId=machine",
                "claude://code/continue?session=local_x&run=x", "claude://code/continue?session=../../x",
                "claude://code/cse_remote-1?run=x", "claude://code/cse_remote%2Fother", "claude://user@code/session_remote"] {
        assert(validatedSourceURL(url) == nil)
    }
}

@MainActor
private final class HoverCheckPanel: NSPanel {
    override var isVisible: Bool { true }
}

@MainActor
func runHoverTrackingChecks() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let panel = HoverCheckPanel(contentRect: NSRect(x: 200, y: 300, width: 216, height: 34),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let view = IslandHostingView(rootView: Color.clear)
    panel.contentView = view
    view.frame = NSRect(origin: .zero, size: panel.frame.size)
    var pointer = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    var observations: [Bool] = []
    var moves: [NSPoint] = []
    view.pointerLocation = { pointer }
    view.onPointerChange = { observations.append($0) }
    view.onPointerMove = { moves.append($0) }
    view.updateTrackingAreas()
    assert(view.trackingAreas.contains {
        ($0.owner as? NSView) === view && $0.options.contains(.activeAlways) &&
        $0.options.contains(.mouseEnteredAndExited) && $0.options.contains(.mouseMoved) && $0.options.contains(.inVisibleRect)
    }, "Hover tracking and tab hover must work when the panel is not the active window")
    let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
    let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 2, trackingNumber: 0, userData: nil)!
    let move = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, eventNumber: 3, clickCount: 0, pressure: 0)!
    view.mouseEntered(with: enter)
    assert(observations.last == true)
    assert(moves.isEmpty, "An entry alone, which resizing also generates, must not count as pointer movement")
    view.mouseMoved(with: move)
    assert(moves == [pointer], "Pointer movement inside the panel is reported in screen coordinates")
    let center = panel.frame.midX, top = panel.frame.maxY
    panel.setFrame(NSRect(x: center - 220, y: top - 210, width: 440, height: 210), display: false)
    view.frame = NSRect(origin: .zero, size: panel.frame.size)
    view.updateTrackingAreas()
    view.mouseExited(with: exit)
    assert(observations.last == true, "A resize-generated exit must not close a panel still under the pointer")
    pointer = NSPoint(x: panel.frame.maxX - 20, y: panel.frame.minY + 20)
    view.mouseEntered(with: enter)
    assert(observations.last == true, "The expanded task list must keep the panel open")
    pointer = NSPoint(x: panel.frame.maxX + 30, y: panel.frame.minY)
    view.mouseExited(with: exit)
    assert(observations.last == false)
    view.mouseMoved(with: move)
    assert(moves.count == 1, "Movement outside the panel is not reported")
    panel.contentView = nil
    print("PASS: native inactive-window hover tracking, resize reconciliation and expanded-body bounds; no window shown or cursor moved.")
}

/// The real panel view, offscreen: the summary tabs report frames that land, on
/// screen, inside the panel's top bar, left to right, where hover selection looks.
@MainActor
func runHoverTabGeometryChecks() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    // Floating compact and open, then the island compact and open beside a 210pt housing.
    let configurations: [(expanded: Bool, safeTop: CGFloat, notch: CGFloat, leading: CGFloat, frame: NSRect)] = [
        (false, 0, 0, 0, NSRect(x: 200, y: 300, width: 216, height: 34)),
        (true, 0, 0, 0, NSRect(x: 88, y: 300, width: 440, height: 272)),
        (false, 32, 210, 52, NSRect(x: 599, y: 950, width: 350, height: 32)),
        (true, 32, 210, 115, NSRect(x: 536, y: 712, width: 440, height: 270)),
    ]
    for config in configurations {
        let model = LiveModel(stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("task-island-render-unused"),
                              persist: false)
        model.expanded = config.expanded
        model.safeTop = config.safeTop
        model.notchWidth = config.notch
        model.notchLeading = config.leading
        let panel = HoverCheckPanel(contentRect: config.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let view = IslandHostingView(rootView: TaskIslandView(model: model, synthetic: true, quit: {}))
        panel.contentView = view
        view.frame = NSRect(origin: .zero, size: config.frame.size)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        view.layoutSubtreeIfNeeded()
        let tabs = model.tabFrames.compactMapValues { view.screenRect(fromSwiftUI: $0) }
        assert(Set(tabs.keys) == [.running, .input, .review], "Every summary tab reports its frame")
        let running = tabs[.running]!, input = tabs[.input]!, review = tabs[.review]!
        assert(running.maxX <= input.minX + 0.5 && input.maxX <= review.minX + 0.5, "Tabs run left to right on screen")
        // The tabs sit in the bar under the menu bar when floating, beside the housing when docked.
        let barHeight = config.notch > 0 ? config.safeTop : 34
        let bar = NSRect(x: panel.frame.minX, y: panel.frame.maxY - barHeight, width: panel.frame.width, height: barHeight)
        for tab in [running, input, review] {
            assert(tab.width > 20 && bar.insetBy(dx: -0.5, dy: -0.5).contains(tab), "A tab lies inside the panel's top bar on screen")
        }
        if config.notch > 0 {
            let housing = NSRect(x: 756 - 105, y: bar.minY, width: config.notch, height: barHeight)
            assert(running.maxX <= housing.minX + 0.5 && input.minX >= housing.maxX - 0.5,
                   "Running is left of the camera housing, Input and Review right of it; nothing is drawn under it")
            assert(HoverTabSelector<TaskSection>.tab(at: NSPoint(x: housing.midX, y: housing.midY), in: tabs) == nil)
        }
        assert(HoverTabSelector<TaskSection>.tab(at: NSPoint(x: running.midX, y: running.midY), in: tabs) == .running)
        assert(HoverTabSelector<TaskSection>.tab(at: NSPoint(x: review.midX, y: review.midY), in: tabs) == .review)
        assert(HoverTabSelector<TaskSection>.tab(at: NSPoint(x: panel.frame.midX, y: panel.frame.minY + 1), in: tabs) == nil,
               "The panel's bottom edge is not a tab")
        panel.contentView = nil
    }
    print("PASS: native tab hover geometry: compact, open and notch-attached tabs measured on screen; no window shown or cursor moved.")
}

@MainActor
func renderPreview(to path: String, collapsed: Bool, floating: Bool, allTasks: Bool = false, afterReview: Bool = false, running: Bool = false, input: Bool = false, largeCounts: Bool = false, longTitle: Bool = false, reviewOnly: Bool = false, empty: Bool = false) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let now = Date().timeIntervalSince1970 * 1000
    let model = LiveModel(stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("task-island-render-unused"),
                          persist: false)
    var tasks = [
        LiveTask(id: "codex:sample-1", provider: "codex", title: "Check search field focus", state: .review,
                 resultKey: "result:sample-turn-1", sourceURL: "codex://threads/sample-1?hostId=durable", observedAt: now, evidence: "live", updatedAt: now),
        LiveTask(id: "claude:local_sample2", provider: "claude", title: "Compare interface designs", state: .review,
                 resultKey: "result:sample-turn-2", sourceURL: "claude://code/continue?session=local_sample2", observedAt: now, evidence: "live", updatedAt: now),
        LiveTask(id: "codex:sample-3", provider: "codex", title: "Check keyboard navigation", state: .running,
                 resultKey: nil, sourceURL: nil, observedAt: now, evidence: "live", updatedAt: now),
        LiveTask(id: "claude:local_sample-4", provider: "claude", title: "Confirm deployment target", state: .input,
                 resultKey: nil, sourceURL: nil, observedAt: now, evidence: "live", updatedAt: now),
        LiveTask(id: "codex:sample-5", provider: "codex", title: "Disconnected example task", state: .unknown,
                 resultKey: nil, sourceURL: nil, observedAt: now, evidence: "unavailable", updatedAt: now),
        LiveTask(id: "claude:session_sample_old", provider: "claude", title: "Check data indexing", state: .unknown,
                 resultKey: nil, sourceURL: "claude://code/session_sample_old", observedAt: now - 300_000,
                 evidence: "history", updatedAt: now - 300_000, observationSource: "claude-cache",
                 availabilityReason: "stale-cache", lastObservedState: .running),
    ]
    if longTitle {
        tasks[0].title = String(String(repeating: "Review a long task title without hiding its actions. ", count: 20).prefix(500))
    }
    if largeCounts {
        for state in [LiveState.running, .input, .review] {
            for index in 0..<120 {
                tasks.append(LiveTask(id: "codex:large-\(state.rawValue)-\(index)", provider: "codex", title: "Example task \(index)", state: state,
                    resultKey: state == .review ? "result:large-\(index)" : nil, sourceURL: nil,
                    observedAt: now, evidence: "live", updatedAt: now))
            }
        }
    }
    if reviewOnly { tasks = tasks.filter { $0.state == .review } }
    if empty { tasks = [] }
    model.apply(LiveSnapshot(type: "snapshot", version: 1, generatedAt: now,
                             providers: [ProviderState(id: "codex", health: "live"), ProviderState(id: "claude", health: "live")],
                             tasks: tasks))
    var updated = tasks
    if let index = updated.firstIndex(where: { $0.id == "codex:sample-1" }) {
        updated[index] = LiveTask(id: "codex:sample-1", provider: "codex", title: tasks[index].title, state: .review,
            resultKey: "result:sample-turn-3", sourceURL: "codex://threads/sample-1?hostId=durable",
            observedAt: now, evidence: "live", updatedAt: now)
    }
    model.apply(LiveSnapshot(type: "snapshot", version: 1, generatedAt: now,
        providers: [ProviderState(id: "codex", health: "live"), ProviderState(id: "claude", health: "live")], tasks: updated))
    if afterReview, let group = model.currentReviewGroup { model.markReviewed(group) }
    model.selection = running ? .running : input ? .input : allTasks ? .all : .review
    model.safeTop = floating ? 0 : 32
    model.notchWidth = floating ? 0 : 210
    model.notchLeading = floating ? 0 : collapsed ? PanelLayout.leftEarWidth : (440 - 210) / 2
    model.expanded = !collapsed
    let view = NSHostingView(rootView: TaskIslandView(model: model, synthetic: true, quit: {}))
    let screen = ScreenMetrics(frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
                               visibleFrame: NSRect(x: 0, y: 38, width: 1512, height: 906), safeTop: 32, housingWidth: 210)
    let size = PanelLayout.frame(metrics: screen, expanded: !collapsed, forceFloating: floating, expandedHeight: model.preferredPanelHeight).size
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw NSError(domain: "TaskIsland", code: 1)
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "TaskIsland", code: 2) }
    try data.write(to: URL(fileURLWithPath: path))
}

@main
struct TaskIslandMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        // A test app relaunched by a UI tool must never fall back to real data.
        if Bundle.main.bundleIdentifier == "local.taskisland.fixture" && !args.contains("--ui-fixture") {
            fputs("Test app requires an isolated fixture scenario.\n", stderr); exit(2)
        }
        if let index = args.firstIndex(of: "--confirm-captured-reviews") {
            guard index + 1 < args.count else { exit(2) }
            do { try confirmCapturedReviews(from: args[index + 1]) }
            catch { fputs("Captured review confirmation failed; existing records were preserved.\n", stderr); exit(1) }
            return
        }
        if args.contains("--self-check") {
            do {
                runGeometryChecks()
                runHoverTrackingChecks()
                runHoverTabGeometryChecks()
                try runModelSelfChecks()
                print("PASS: native geometry, URL validation, live metadata model and durable review ledger. No GUI or live bridge started.")
            } catch {
                fputs("Native self-check failed. No live bridge started.\n", stderr)
                exit(1)
            }
            return
        }
        if let index = args.firstIndex(of: "--render-preview") {
            guard index + 1 < args.count else { fputs("Missing preview output path.\n", stderr); exit(2) }
            do { try renderPreview(to: args[index + 1], collapsed: args.contains("--collapsed"), floating: args.contains("--floating"),
                                  allTasks: args.contains("--preview-all"), afterReview: args.contains("--preview-after-review"),
                                  running: args.contains("--preview-running"), input: args.contains("--preview-input"),
                                  largeCounts: args.contains("--preview-large-counts"), longTitle: args.contains("--preview-long-title"),
                                  reviewOnly: args.contains("--preview-review-only"), empty: args.contains("--preview-empty")) }
            catch { fputs("Synthetic preview rendering failed.\n", stderr); exit(1) }
            return
        }
        do {
            let options = try LaunchOptions.parse(args)
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate(options: options)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch {
            fputs("Invalid Monita launch arguments.\n", stderr)
            exit(2)
        }
    }
}

