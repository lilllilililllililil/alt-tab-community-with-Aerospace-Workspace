import Cocoa

class SleepWakeEvents {
    static func observe() {
        // system sleep/wake and display sleep/wake both suspend our event taps long enough for macOS to
        // disable them with kCGEventTapDisabledByTimeout; we re-enable them on resume (#5723)
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    @objc private static func handleWake(_ notification: Notification) {
        Logger.info { "" }
        AeroSpaceWorkspaceCards.shared.notifyWindowServerChange(topologyChanged: true)
        reEnableAllTaps()
        // AeroSpace needs a moment to fully restart after wake. The immediate query
        // often exits with code 2 (suspending all further queries). Issue a forced
        // probe after 2.5 s so we don't wait the full 60 s recovery timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            AeroSpaceWorkspaceCards.shared.refresh(forceProbe: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { reEnableAllTaps() }
    }

    static func reEnableAllTaps() {
        TrackpadEvents.reEnableTapIfNeeded()
        ScrollwheelEvents.reEnableTapIfNeeded()
        KeyboardEvents.reEnableTapIfNeeded()
        CursorEvents.reEnableTapIfNeeded()
    }
}
