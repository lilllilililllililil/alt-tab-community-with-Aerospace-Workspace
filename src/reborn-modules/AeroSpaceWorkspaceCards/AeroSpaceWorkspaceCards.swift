import AppKit
import Foundation

/// Portable AeroSpace integration. AeroSpace owns topology; AltTab owns windows, MRU, and thumbnails.
final class AeroSpaceWorkspaceCards {
    static let shared = AeroSpaceWorkspaceCards()
    static let managedWorkspaces: Set<String> = ["2", "3", "4", "5"]
    static let proxyAspectRatio = CGSize(width: 16, height: 10)

    struct Entry: Decodable {
        let windowId: UInt32
        let workspace: String
        enum CodingKeys: String, CodingKey { case windowId = "window-id", workspace }
    }
    struct SubscriptionEvent: Decodable {
        let event: String
        let workspace: String?
        let prevWorkspace: String?
        enum CodingKeys: String, CodingKey {
            case event = "_event", workspace, prevWorkspace
        }
    }

    struct Card {
        let workspace: String
        let representative: Window
        let windows: [Window]
        let frames: [CGWindowID: CGRect]
    }

    private(set) var focusedWorkspace = "⠀"
    private var membership = [CGWindowID: String]()
    private var layoutCache = [String: [CGWindowID: CGRect]]()
    private var cardsByRepresentative = [CGWindowID: Card]()
    private var stickyRepresentativeByWorkspace = [String: CGWindowID]()
    private var hasCompletedInitialRefresh = false
    private var recoveryTimer: Timer?
    private var subscriptionProcess: Process?
    private var subscriptionPipe: Pipe?
    private var subscriptionBuffer = Data()
    private var subscriptionRestartWorkItem: DispatchWorkItem?
    private var topologyRefreshWorkItem: DispatchWorkItem?
    private var topologyRefreshDeadline: TimeInterval?
    private var topologyRefreshGeneration: UInt64 = 0
    private var geometryRefreshWorkItem: DispatchWorkItem?
    private var subscriptionGeneration: UInt64 = 0
    private var subscriptionFailureCount = 0
    private var monitoringEnabled = false
    private var queryInFlight = false
    private var pendingRefresh = false
    private var topologyQueriesSuspended = false
    private var refreshNeededAfterWake = false
    private var revision: UInt64 = 0
    private var consecutiveRefreshFailures = 0
    private var lastStateFingerprint = ""
    private let executable = "/opt/homebrew/bin/aerospace"

    // Temporary performance trace. Enable before launching AltTab with:
    // defaults write com.lwouis.alt-tab-macos AeroSpaceTransitionTraceEnabled -bool true
    // The flag is read once at process start, so disabled tracing adds only one cached Bool branch.
    private static let traceEnabled = UserDefaults.standard.bool(forKey: "AeroSpaceTransitionTraceEnabled")
    private static let traceQueue = DispatchQueue(label: "com.lwouis.alt-tab-macos.aerospace-transition-trace", qos: .utility)
    private static let traceStartedAt = ProcessInfo.processInfo.systemUptime
    private static var traceSequence: UInt64 = 0
    private static var traceHandle: FileHandle?

    private static func trace(_ event: String, _ fields: [String: Any] = [:]) {
        guard traceEnabled else { return }
        let uptimeMs = Int((ProcessInfo.processInfo.systemUptime - traceStartedAt) * 1000)
        let wallTime = ISO8601DateFormatter().string(from: Date())
        traceQueue.async {
            traceSequence &+= 1
            var object = fields
            object["seq"] = traceSequence
            object["event"] = event
            object["wallTime"] = wallTime
            object["uptimeMs"] = uptimeMs
            guard JSONSerialization.isValidJSONObject(object),
                  let payload = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AltTab Reborn")
            let url = directory.appendingPathComponent("AeroSpaceTransitionTrace.jsonl")
            if traceHandle == nil {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                traceHandle = try? FileHandle(forWritingTo: url)
                traceHandle?.seekToEndOfFile()
            }
            guard let handle = traceHandle else { return }
            handle.write(payload + Data([0x0A]))
        }
    }

    private static func elapsedMs(since start: TimeInterval) -> Int {
        Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    func traceUiEvent(_ event: String, shortcutIndex: Int? = nil, selectedWindow: Window? = nil) {
        var fields: [String: Any] = [
            "focusedWorkspaceCache": focusedWorkspace,
            "membershipCount": membership.count,
            "queryInFlight": queryInFlight,
            "pendingRefresh": pendingRefresh,
        ]
        if let shortcutIndex { fields["shortcutIndex"] = shortcutIndex }
        if let selectedWindow {
            fields["windowId"] = selectedWindow.cgWindowId.map(Int.init) ?? -1
            fields["targetWorkspaceCache"] = selectedWindow.cgWindowId.flatMap { membership[$0] } ?? "unknown"
            fields["isWorkspaceProxy"] = card(for: selectedWindow) != nil
        }
        Self.trace(event, fields)
    }

    var enabled: Bool { Preferences.aeroSpaceWorkspaceCards }
    var isThumbnailMode: Bool {
        Preferences.effectiveAppearanceStyle(SwitcherSession.activeShortcutIndex) == .thumbnails
    }

    func reconcileMonitoring() {
        if enabled {
            if !monitoringEnabled { start() }
        } else if monitoringEnabled {
            stop()
        }
    }

    func stop() {
        monitoringEnabled = false
        subscriptionGeneration &+= 1
        subscriptionRestartWorkItem?.cancel()
        topologyRefreshGeneration &+= 1
        topologyRefreshWorkItem?.cancel()
        topologyRefreshWorkItem = nil
        topologyRefreshDeadline = nil
        geometryRefreshWorkItem?.cancel()
        geometryRefreshWorkItem = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        subscriptionPipe?.fileHandleForReading.readabilityHandler = nil
        subscriptionProcess?.terminationHandler = nil
        if subscriptionProcess?.isRunning == true { subscriptionProcess?.terminate() }
        subscriptionProcess = nil
        subscriptionPipe = nil
        subscriptionBuffer.removeAll(keepingCapacity: false)
        pendingRefresh = false
        topologyQueriesSuspended = false
        refreshNeededAfterWake = false
        hasCompletedInitialRefresh = false
        stickyRepresentativeByWorkspace.removeAll(keepingCapacity: false)
        cardsByRepresentative.removeAll(keepingCapacity: false)
    }

    func start() {
        guard enabled, recoveryTimer == nil else { return }
        monitoringEnabled = true
        refresh()
        startSubscription()
        // Rare safety net only. Normal updates are event-driven.
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.refresh(forceProbe: true)
        }
        recoveryTimer?.tolerance = 15.0
    }

    private func startSubscription() {
        guard enabled, subscriptionProcess == nil,
              FileManager.default.isExecutableFile(atPath: executable) else { return }
        subscriptionRestartWorkItem?.cancel()
        subscriptionBuffer.removeAll(keepingCapacity: true)

        subscriptionGeneration &+= 1
        let generation = subscriptionGeneration
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["subscribe", "--no-send-initial", "focused-workspace-changed", "focus-changed", "window-detected"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        subscriptionProcess = process
        subscriptionPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                Self.trace("subscription.stdout.eof", ["generation": generation])
                return
            }
            DispatchQueue.main.async {
                guard let self, generation == self.subscriptionGeneration, self.monitoringEnabled else { return }
                self.consumeSubscriptionData(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, generation == self.subscriptionGeneration else { return }
                self.subscriptionDidTerminate(generation: generation)
            }
        }
        do {
            try process.run()
        } catch {
            subscriptionDidTerminate(generation: generation)
        }
    }

    private func subscriptionDidTerminate(generation: UInt64) {
        guard generation == subscriptionGeneration else { return }
        subscriptionPipe?.fileHandleForReading.readabilityHandler = nil
        subscriptionProcess = nil
        subscriptionPipe = nil
        guard enabled, monitoringEnabled else { return }
        let delays: [TimeInterval] = [2, 5, 15, 30, 30]
        let delay = delays[min(subscriptionFailureCount, delays.count - 1)]
        subscriptionFailureCount = min(subscriptionFailureCount + 1, delays.count - 1)
        let work = DispatchWorkItem { [weak self] in self?.startSubscription() }
        subscriptionRestartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func consumeSubscriptionData(_ data: Data) {
        subscriptionBuffer.append(data)
        while let newline = subscriptionBuffer.firstIndex(of: 0x0A) {
            let line = subscriptionBuffer.prefix(upTo: newline)
            subscriptionBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let event = try JSONDecoder().decode(SubscriptionEvent.self, from: Data(line))
                handleSubscriptionEvent(event)
            } catch {
                Self.trace("subscription.decode.failed", [
                    "bytes": line.count,
                    "error": String(describing: error),
                ])
            }
        }
    }

    private func handleSubscriptionEvent(_ event: SubscriptionEvent) {
        subscriptionFailureCount = 0
        resumeTopologyQueries(source: "subscription.\(event.event)")
        if event.event == "focused-workspace-changed", let workspace = event.workspace {
            focusedWorkspace = workspace
            scheduleTopologyRefresh(delay: 0.10)
        } else if event.event == "focus-changed" {
            if let workspace = event.workspace { focusedWorkspace = workspace }
            scheduleGeometryRefresh(delay: 0.08)
        } else if event.event == "window-detected" {
            scheduleTopologyRefresh(delay: 0.15)
        }
    }

    /// Called by AltTab's existing WindowServer stream. Geometry changes are local and need no CLI.
    func notifyWindowServerChange(topologyChanged: Bool) {
        guard enabled else { return }
        if topologyChanged {
            scheduleTopologyRefresh(delay: 0.18)
        } else {
            scheduleGeometryRefresh(delay: 0.20)
        }
    }

    private func scheduleTopologyRefresh(delay: TimeInterval) {
        if topologyQueriesSuspended {
            if !refreshNeededAfterWake {
                Self.trace("refresh.skipped.disabled", ["delayMs": Int(delay * 1000)])
            }
            refreshNeededAfterWake = true
            return
        }
        if queryInFlight {
            if !pendingRefresh {
                Self.trace("refresh.coalesced", ["reason": "scheduledWhileQueryInFlight"])
            }
            pendingRefresh = true
            return
        }

        let proposedDeadline = ProcessInfo.processInfo.systemUptime + delay
        if let currentDeadline = topologyRefreshDeadline,
           topologyRefreshWorkItem != nil,
           currentDeadline <= proposedDeadline {
            return
        }

        let replacedPendingWork = topologyRefreshWorkItem != nil
        topologyRefreshGeneration &+= 1
        let generation = topologyRefreshGeneration
        topologyRefreshWorkItem?.cancel()
        topologyRefreshDeadline = proposedDeadline
        Self.trace("refresh.topology.scheduled", [
            "delayMs": Int(delay * 1000),
            "replacedPendingWork": replacedPendingWork,
        ])
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.topologyRefreshGeneration else { return }
            self.topologyRefreshWorkItem = nil
            self.topologyRefreshDeadline = nil
            self.refresh()
        }
        topologyRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleGeometryRefresh(delay: TimeInterval) {
        geometryRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.geometryRefreshWorkItem = nil
            self.captureActiveLayout()
        }
        geometryRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func suspendTopologyQueries(status: Int32) {
        queryInFlight = false
        pendingRefresh = false
        let wasSuspended = topologyQueriesSuspended
        topologyQueriesSuspended = true
        refreshNeededAfterWake = false
        if !wasSuspended {
            Self.trace("refresh.suspended", ["status": status])
        }
    }
    private func resumeTopologyQueries(source: String) {
        guard topologyQueriesSuspended else { return }
        topologyQueriesSuspended = false
        let needsRefresh = refreshNeededAfterWake
        refreshNeededAfterWake = false
        Self.trace("refresh.resumed", ["source": source, "refreshNeeded": needsRefresh])
    }
    /// Background cache refresh. This is never called from shortcut/show/navigation paths.
    /// forceProbe is reserved for the low-frequency recovery timer while AeroSpace is OFF.
    private func refresh(forceProbe: Bool = false) {
        guard enabled, FileManager.default.isExecutableFile(atPath: executable) else { return }
        guard forceProbe || !topologyQueriesSuspended else {
            refreshNeededAfterWake = true
            return
        }
        if queryInFlight {
            pendingRefresh = true
            Self.trace("refresh.coalesced", ["reason": "queryInFlight"])
            return
        }
        queryInFlight = true
        let refreshStartedAt = ProcessInfo.processInfo.systemUptime
        Self.trace("refresh.started")
        run(["list-windows", "--all", "--json", "--format", "%{window-id} %{workspace}"]) { [weak self] status, data in
            guard let self else { return }
            guard status == 0, let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
                self.consecutiveRefreshFailures += 1
                Self.trace("refresh.finished", ["ok": false, "stage": "listWindows", "status": status, "durationMs": Self.elapsedMs(since: refreshStartedAt)])
                if status == 2 {
                    self.suspendTopologyQueries(status: status)
                } else {
                    self.finishRefresh()
                }
                return
            }
            self.resumeTopologyQueries(source: forceProbe ? "recoveryProbe" : "listWindows.success")
            self.run(["list-workspaces", "--focused"]) { [weak self] focusStatus, focusData in
                guard let self else { return }
                self.finishRefresh()
                guard focusStatus == 0,
                      let value = String(data: focusData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else {
                    self.consecutiveRefreshFailures += 1
                    Self.trace("refresh.finished", ["ok": false, "stage": "focusedWorkspace", "status": focusStatus, "durationMs": Self.elapsedMs(since: refreshStartedAt)])
                    return
                }
                self.consecutiveRefreshFailures = 0
                self.apply(entries, focusedWorkspace: value)
                self.hasCompletedInitialRefresh = true
                Self.trace("refresh.finished", ["ok": true, "entries": entries.count, "workspace": value, "durationMs": Self.elapsedMs(since: refreshStartedAt)])
            }
        }
    }

    private func finishRefresh() {
        queryInFlight = false
        guard pendingRefresh else { return }
        pendingRefresh = false
        scheduleTopologyRefresh(delay: 0.05)
    }

    private func setKarabinerSleepingState(_ sleeping: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli")
        process.arguments = ["--set-variables", "{\"aerospace_sleeping\":\(sleeping)}"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }

    /// Fast cross-mode phase. Wait only for the authoritative workspace transition.
    /// The potentially slower empty-workspace check runs after the target window receives focus.
    private func transitionToDefaultWorkspace(completion: @escaping (Bool) -> Void) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        Self.trace("transition.default.workspace.started", ["fromWorkspaceCache": focusedWorkspace])
        run(["workspace", "⠀"]) { status, _ in
            Self.trace("transition.default.workspace.finished", [
                "status": status,
                "durationMs": Self.elapsedMs(since: startedAt),
            ])
            completion(status == 0)
        }
    }

    /// Post-focus maintenance. One targeted authoritative query decides whether AeroSpace may sleep.
    /// Query, parse, or disable failure is fail-open, so AeroSpace remains enabled.
    private func sleepAeroSpaceIfManagedWorkspacesAreEmpty() {
        let startedAt = ProcessInfo.processInfo.systemUptime
        Self.trace("transition.default.sleepCheck.started")
        run(["list-windows", "--workspace", "2", "3", "4", "5", "--count"]) { [weak self] status, data in
            guard let self else { return }
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard status == 0, let output, let count = Int(output) else {
                Self.trace("transition.default.sleepCheck.finished", [
                    "status": status,
                    "result": "queryFailedKeptEnabled",
                    "durationMs": Self.elapsedMs(since: startedAt),
                ])
                return
            }
            guard count == 0 else {
                Self.trace("transition.default.sleepCheck.finished", [
                    "status": status,
                    "result": "keptEnabledManagedWindowsExist",
                    "managedWindowCount": count,
                    "durationMs": Self.elapsedMs(since: startedAt),
                ])
                return
            }
            self.run(["enable", "off"]) { disableStatus, _ in
                if disableStatus == 0 {
                    self.setKarabinerSleepingState(true)
                }
                Self.trace("transition.default.sleepCheck.finished", [
                    "status": disableStatus,
                    "result": disableStatus == 0
                        ? "disabledManagedWorkspacesEmpty"
                        : "disableFailedKeptEnabled",
                    "managedWindowCount": count,
                    "durationMs": Self.elapsedMs(since: startedAt),
                ])
            }
        }
    }
    private func run(_ arguments: [String], completion: @escaping (Int32, Data) -> Void) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        process.terminationHandler = { task in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async { completion(task.terminationStatus, data) }
        }
        do { try process.run() } catch { DispatchQueue.main.async { completion(-1, Data()) } }
    }

    private func apply(_ entries: [Entry], focusedWorkspace: String) {
        self.focusedWorkspace = focusedWorkspace
        membership = Dictionary(
            entries.map { (CGWindowID($0.windowId), $0.workspace) },
            uniquingKeysWith: { _, new in new }
        )
        captureActiveLayout()
        let fingerprint = stateFingerprint(entries)
        guard fingerprint != lastStateFingerprint else { return }
        lastStateFingerprint = fingerprint
        revision &+= 1
        #if DEBUG
        writeDiagnostics(entries)
        #endif
    }

    /// Frames are trusted only while AeroSpace says that workspace is focused.
    private func captureActiveLayout() {
        guard Self.managedWorkspaces.contains(focusedWorkspace), let screen = NSScreen.main?.frame else { return }
        var frames = [CGWindowID: CGRect]()
        for window in Windows.list where !window.isFullscreen {
            guard let wid = window.cgWindowId, membership[wid] == focusedWorkspace,
                  let position = window.position, let size = window.size,
                  size.width > 0, size.height > 0 else { continue }
            frames[wid] = CGRect(x: (position.x - screen.minX) / screen.width,
                                 y: (position.y - screen.minY) / screen.height,
                                 width: size.width / screen.width,
                                 height: size.height / screen.height)
        }
        if !frames.isEmpty { layoutCache[focusedWorkspace] = frames }
    }

    /// Pure projection over cached state. It performs no process, capture, AX, or disk operation.
    func applyProjection() {
        reconcileMonitoring()
        cardsByRepresentative.removeAll(keepingCapacity: true)
        guard enabled, isThumbnailMode, hasCompletedInitialRefresh else { return }
        let candidates = Windows.list.filter {
            guard let wid = $0.cgWindowId, !$0.isFullscreen, $0.shouldShowTheUser,
                  let workspace = membership[wid] else { return false }
            return Self.managedWorkspaces.contains(workspace)
        }
        let groups = Dictionary(grouping: candidates) { membership[$0.cgWindowId!]! }
        let activeWorkspaces = Set(groups.keys)
        stickyRepresentativeByWorkspace = stickyRepresentativeByWorkspace.filter { activeWorkspaces.contains($0.key) }

        for workspace in Self.managedWorkspaces.sorted() {
            guard let members = groups[workspace], !members.isEmpty else { continue }
            let ordered = members.sorted { $0.lastFocusOrder < $1.lastFocusOrder }

            let representative: Window
            if let stickyId = stickyRepresentativeByWorkspace[workspace],
               let stickyWindow = ordered.first(where: { $0.cgWindowId == stickyId }) {
                representative = stickyWindow
            } else {
                guard let initialRepresentative = ordered.first,
                      let initialId = initialRepresentative.cgWindowId else { continue }
                representative = initialRepresentative
                stickyRepresentativeByWorkspace[workspace] = initialId
            }

            guard let representativeId = representative.cgWindowId else { continue }
            ordered.filter { $0.cgWindowId != representativeId }.forEach { $0.shouldShowTheUser = false }
            cardsByRepresentative[representativeId] = Card(workspace: workspace,
                                                           representative: representative,
                                                           windows: ordered,
                                                           frames: layoutCache[workspace] ?? [:])
        }
    }

    func card(for window: Window) -> Card? { window.cgWindowId.flatMap { cardsByRepresentative[$0] } }

    func previewSize(for window: Window, fallback: NSSize?) -> NSSize? {
        guard card(for: window) != nil else { return fallback }
        let height = TileView.maxThumbnailHeight() - Appearance.edgeInsetsSize * 2 - Appearance.intraCellPadding - Appearance.iconSize
        return NSSize(width: height * Self.proxyAspectRatio.width / Self.proxyAspectRatio.height, height: height)
    }

    enum GroupAction { case close, minimize, hide, quit, fullscreen }

    @discardableResult
    func performGroupAction(_ action: GroupAction, selected window: Window?) -> Bool {
        guard isThumbnailMode, let window, let card = card(for: window) else { return false }
        let windows = card.windows.filter { !$0.isFullscreen && $0.cgWindowId != nil }
        guard !windows.isEmpty else { return true }
        let representativeId = card.representative.cgWindowId
        let ordered = windows.sorted {
            if $0.cgWindowId == representativeId { return false }
            if $1.cgWindowId == representativeId { return true }
            return $0.lastFocusOrder > $1.lastFocusOrder
        }
        switch action {
        case .close:
            ordered.forEach { $0.close() }
        case .minimize:
            let target = ordered.contains { !$0.isMinimized }
            ordered.forEach { $0.setMinimized(target) }
        case .hide:
            let apps = uniqueApplications(ordered)
            let targetHidden = apps.contains { !$0.runningApplication.isHidden }
            apps.forEach { app in
                if app.runningApplication.isHidden != targetHidden { app.hideOrShow() }
            }
        case .quit:
            uniqueApplications(ordered).forEach { $0.quit() }
        case .fullscreen:
            return false
        }
        return true
    }

    private func uniqueApplications(_ windows: [Window]) -> [Application] {
        var seen = Set<pid_t>()
        return windows.compactMap { window in
            let app = window.application
            guard seen.insert(app.pid).inserted else { return nil }
            return app
        }
    }

    /// Routes activation without adding work to ordinary same-mode switching.
    /// - Workspace proxy 2-5: enable AeroSpace, then focus its representative window.
    /// - Ordinary U+2800 window while already on U+2800: return false for native window.focus().
    /// - Ordinary U+2800 window while on 2-5: enter U+2800, conditionally sleep AeroSpace, then focus.
    /// - Unknown/non-U+2800 ordinary targets: return false and preserve AltTab's native behavior.
    func activate(_ window: Window, ordinaryActivation: @escaping () -> Void) -> Bool {
        guard enabled, isThumbnailMode else { return false }
        let windowId = window.cgWindowId.map(Int.init) ?? -1
        let targetWorkspace = window.cgWindowId.flatMap { membership[$0] } ?? "unknown"

        if let card = card(for: window) {
            let startedAt = ProcessInfo.processInfo.systemUptime
            Self.trace("activation.route", ["route": "workspaceProxy", "windowId": windowId, "fromWorkspaceCache": focusedWorkspace, "targetWorkspace": card.workspace])
            run(["enable", "on"]) { [weak self, weak representative = card.representative] status, _ in
                Self.trace("activation.proxy.enable.finished", ["status": status, "durationMs": Self.elapsedMs(since: startedAt), "targetWorkspace": card.workspace])
                guard let self, status == 0 else { return }
                self.setKarabinerSleepingState(false)
                self.resumeTopologyQueries(source: "workspaceProxy.enable")
                // Focus is latency-critical; the cache refresh remains asynchronous.
                representative?.focus()
                self.scheduleTopologyRefresh(delay: 0.10)
            }
            return true
        }

        guard let cgWindowId = window.cgWindowId, membership[cgWindowId] == "⠀" else {
            Self.trace("activation.route", ["route": "nativeUnknown", "windowId": windowId, "fromWorkspaceCache": focusedWorkspace, "targetWorkspace": targetWorkspace])
            return false
        }

        // Fast path: switching between ordinary windows on U+2800 remains a native focus only.
        guard Self.managedWorkspaces.contains(focusedWorkspace) else {
            Self.trace("activation.route", ["route": "nativeDefaultWorkspace", "windowId": windowId, "fromWorkspaceCache": focusedWorkspace, "targetWorkspace": "⠀"])
            return false
        }

        Self.trace("activation.route", ["route": "crossToDefault", "windowId": windowId, "fromWorkspaceCache": focusedWorkspace, "targetWorkspace": "⠀"])
        transitionToDefaultWorkspace { [weak self] transitionSucceeded in
            Self.trace("activation.cross.focusDecision", ["transitionSucceeded": transitionSucceeded, "windowId": windowId])
            guard let self, transitionSucceeded else {
                // Fail safely without creating a cross-workspace overlay when the transition failed.
                return
            }
            ordinaryActivation()
            Self.trace("activation.cross.focusDispatched", ["windowId": windowId])
            self.sleepAeroSpaceIfManagedWorkspacesAreEmpty()
        }
        return true
    }

    func configurePresentation(in view: TileView, for window: Window) {
        clearPresentation(in: view)
        guard isThumbnailMode, let card = card(for: window), !view.thumbnail.isHidden else { return }

        view.thumbnail.isHidden = true
        view.appIcon.isHidden = true
        view.label.stringValue = "Workspace \(card.workspace)"
        view.setAccessibilityLabel("Workspace \(card.workspace)")

        let canvas = view.thumbnail.frame
        let background = CALayer()
        background.frame = canvas
        background.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        background.cornerRadius = 4
        background.masksToBounds = true
        view.layer?.addSublayer(background)
        view.aeroSpaceDecorationLayers.append(background)

        let rawFrames = card.frames.isEmpty ? equalGrid(card.windows) : card.frames
        let frames = normalizedToCanvas(rawFrames, windows: card.windows)
        for member in card.windows.reversed() {
            guard let wid = member.cgWindowId, let normalized = frames[wid] else { continue }
            let layer = LightImageLayer()
            let content = member.thumbnail ?? .cgImage(member.icon)
            let layerSize = NSSize(width: max(1, canvas.width * normalized.width), height: max(1, canvas.height * normalized.height))
            layer.updateContents(content, layerSize)
            layer.frame.origin = CGPoint(x: canvas.minX + canvas.width * normalized.minX,
                                         y: canvas.minY + canvas.height * normalized.minY)
            layer.masksToBounds = true
            layer.borderWidth = 0.6
            layer.borderColor = NSColor.disabledControlTextColor.cgColor
            view.layer?.addSublayer(layer)
            view.aeroSpacePreviewLayers.append(layer)
        }

        // One full-size icon per window, including duplicate applications, ordered by MRU.
        // The workspace card temporarily extends the normal leading icon strip. clearPresentation()
        // restores AltTab's standard single-line label geometry before a recycled tile is reused.
        let iconSize = max(1, view.appIcon.frame.height)
        let spacing: CGFloat = 3
        let stripWidth = CGFloat(card.windows.count) * iconSize + CGFloat(max(0, card.windows.count - 1)) * spacing
        let y = view.appIcon.frame.minY + max(0, (view.appIcon.frame.height - iconSize) / 2)
        for (index, member) in card.windows.enumerated() {
            let iconLayer = LightImageLayer()
            iconLayer.updateContents(.cgImage(member.icon), NSSize(width: iconSize, height: iconSize))
            iconLayer.frame.origin = CGPoint(x: view.appIcon.frame.minX + CGFloat(index) * (iconSize + spacing), y: y)
            view.layer?.addSublayer(iconLayer)
            view.aeroSpaceIconLayers.append(iconLayer)
        }
        let titleX = view.appIcon.frame.minX + stripWidth + Appearance.appIconLabelSpacing
        view.label.frame.origin.x = titleX
        view.label.setWidth(max(1, view.frame.width - titleX - Appearance.edgeInsetsSize - view.statusIcons.totalWidth))
    }

    private func clearPresentation(in view: TileView) {
        view.aeroSpacePreviewLayers.forEach { $0.removeFromSuperlayer() }
        view.aeroSpaceIconLayers.forEach { $0.removeFromSuperlayer() }
        view.aeroSpaceDecorationLayers.forEach { $0.removeFromSuperlayer() }
        view.aeroSpacePreviewLayers.removeAll(keepingCapacity: true)
        view.aeroSpaceIconLayers.removeAll(keepingCapacity: true)
        view.aeroSpaceDecorationLayers.removeAll(keepingCapacity: true)

        // TileViews are recycled. Always restore AltTab's native title geometry so workspace-card
        // presentation cannot leak into ordinary cards or the selected/current application title.
        let edgeInsets = Appearance.edgeInsetsSize
        let contentWidth = view.frame.width - edgeInsets * 2
        let standardLabelWidth = contentWidth - view.appIcon.frame.width - Appearance.appIconLabelSpacing - view.statusIcons.totalWidth
        if App.shared.userInterfaceLayoutDirection == .leftToRight {
            view.label.frame.origin.x = view.appIcon.frame.maxX + Appearance.appIconLabelSpacing
        } else {
            view.label.frame.origin.x = edgeInsets + contentWidth - view.appIcon.frame.width - Appearance.appIconLabelSpacing - standardLabelWidth
        }
        view.label.setWidth(max(1, standardLabelWidth))
        view.label.maximumNumberOfLines = 1
        view.label.usesSingleLineMode = true
        view.label.cell?.wraps = false

        view.thumbnail.isHidden = Appearance.hideThumbnails
        view.appIcon.isHidden = false
    }

    /// Preserve overlap and relative z-order. Clamp only the outer canvas, not intersections.
    private func normalizedToCanvas(_ source: [CGWindowID: CGRect], windows: [Window]) -> [CGWindowID: CGRect] {
        let valid = windows.compactMap { window -> CGRect? in
            guard let wid = window.cgWindowId, let rect = source[wid], rect.width > 0, rect.height > 0 else { return nil }
            return rect
        }
        guard let first = valid.first else { return equalGrid(windows) }
        let union = valid.dropFirst().reduce(first) { $0.union($1) }
        guard union.width > 0, union.height > 0 else { return equalGrid(windows) }
        var result = [CGWindowID: CGRect]()
        for window in windows {
            guard let wid = window.cgWindowId, let rect = source[wid] else { continue }
            let normalized = CGRect(x: (rect.minX - union.minX) / union.width,
                                    y: (rect.minY - union.minY) / union.height,
                                    width: rect.width / union.width,
                                    height: rect.height / union.height)
            result[wid] = normalized
        }
        return result
    }

    private func equalGrid(_ windows: [Window]) -> [CGWindowID: CGRect] {
        let count = max(windows.count, 1)
        let columns = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(columns)))
        var result = [CGWindowID: CGRect]()
        for (index, window) in windows.enumerated() {
            guard let wid = window.cgWindowId else { continue }
            result[wid] = CGRect(x: CGFloat(index % columns) / CGFloat(columns),
                                 y: CGFloat(index / columns) / CGFloat(rows),
                                 width: 1 / CGFloat(columns), height: 1 / CGFloat(rows))
        }
        return result
    }

    private func stateFingerprint(_ entries: [Entry]) -> String {
        var parts = ["focus=\(focusedWorkspace)"]
        for entry in entries.sorted(by: { $0.windowId < $1.windowId }) {
            parts.append("w=\(entry.windowId):\(entry.workspace)")
        }
        for workspace in Self.managedWorkspaces.sorted() {
            guard let frames = layoutCache[workspace] else { continue }
            for (windowId, rect) in frames.sorted(by: { $0.key < $1.key }) {
                parts.append(String(format: "f=%@:%u:%.4f:%.4f:%.4f:%.4f", workspace, windowId, rect.origin.x, rect.origin.y, rect.size.width, rect.size.height))
            }
        }
        return parts.joined(separator: "|")
    }

    private func writeDiagnostics(_ entries: [Entry]) {
        let matchedIds = Set(Windows.list.compactMap { $0.cgWindowId })
        let workspaceData = Self.managedWorkspaces.sorted().map { workspace -> [String: Any] in
            let ids = entries.filter { $0.workspace == workspace }.map { Int($0.windowId) }
            return ["workspace": workspace,
                    "aerospaceWindowIds": ids,
                    "matchedAltTabWindowIds": ids.filter { matchedIds.contains(CGWindowID($0)) },
                    "cachedFrameWindowIds": layoutCache[workspace]?.keys.map { Int($0) } ?? []]
        }
        let object: [String: Any] = ["revision": Int(revision),
                                     "consecutiveRefreshFailures": consecutiveRefreshFailures,
                                     "eventDriven": true,
                                     "subscriptionRunning": subscriptionProcess?.isRunning == true,
                                     "subscriptionFailureCount": subscriptionFailureCount,
                                     "monitoringEnabled": monitoringEnabled,
                                     "recoveryIntervalSeconds": 60,
                                     "focusedWorkspace": focusedWorkspace,
                                     "currentWorkspaceIsGrouped": Self.managedWorkspaces.contains(focusedWorkspace),
                                     "policy": "all-managed-workspaces-including-current",
                                     "managedWorkspaces": workspaceData]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AltTab Reborn")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("AeroSpaceWorkspaceCards.json"), options: .atomic)
    }
}
