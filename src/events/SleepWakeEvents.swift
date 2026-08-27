import Cocoa

class SleepWakeEvents {
    private static var aeroSpaceRecoveryWorkItem: DispatchWorkItem?
    private static var suppressAeroSpaceRecoveryUntil: TimeInterval = 0

    static func observe() {
        // system sleep/wake and display sleep/wake both suspend our event taps long enough for macOS to
        // disable them with kCGEventTapDisabledByTimeout; we re-enable them on resume (#5723)
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    @objc private static func handleWake(_ notification: Notification) {
        Logger.info { "" }
        reEnableAllTaps()

        // didWakeNotification and screensDidWakeNotification commonly arrive for the
        // same wake. Coalesce them into one recovery probe. A screen-unlock event has
        // its own authoritative refresh, so it suppresses this fallback entirely.
        let now = ProcessInfo.processInfo.systemUptime
        if now >= suppressAeroSpaceRecoveryUntil {
            aeroSpaceRecoveryWorkItem?.cancel()
            let work = DispatchWorkItem {
                aeroSpaceRecoveryWorkItem = nil
                AeroSpaceWorkspaceCards.shared.refresh(
                    forceProbe: true,
                    source: "systemWakeRecovery"
                )
            }
            aeroSpaceRecoveryWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { reEnableAllTaps() }
    }

    static func screenUnlockHandledAeroSpaceRecovery() {
        suppressAeroSpaceRecoveryUntil = ProcessInfo.processInfo.systemUptime + 3.0
        aeroSpaceRecoveryWorkItem?.cancel()
        aeroSpaceRecoveryWorkItem = nil
    }

    static func reEnableAllTaps() {
        TrackpadEvents.reEnableTapIfNeeded()
        ScrollwheelEvents.reEnableTapIfNeeded()
        KeyboardEvents.reEnableTapIfNeeded()
        CursorEvents.reEnableTapIfNeeded()
    }
}
