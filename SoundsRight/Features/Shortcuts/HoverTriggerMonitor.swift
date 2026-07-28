import AppKit
import os

/// Fires lookups from the mouse alone: after the user selects text in another
/// app (drag-select or double/triple-click) and then lets the pointer rest,
/// `onHover` is invoked. Runs only while Settings → General → Activation is
/// set to Hover.
///
/// The gesture is deliberately two-step — a selection-shaped mouse-up *arms*
/// the monitor for a short window, and the pointer coming to rest *fires* it —
/// so ordinary mouse travel never triggers, and adjusting a selection simply
/// re-arms. Global monitors never see this app's own events, so interacting
/// with the panel or Collection window cannot arm a trigger.
@MainActor
final class HoverTriggerMonitor {
    /// Called on the main actor when the hover gesture completes.
    var onHover: (() -> Void)?

    private var eventMonitor: Any?

    /// Live while a selection gesture is armed: polls the pointer and fires
    /// `onHover` the first time it rests long enough.
    private var dwellTask: Task<Void, Never>?

    /// Farthest the pointer travelled during the current mouse-drag —
    /// distinguishes a text-selection drag from a plain click.
    private var mouseDownLocation: NSPoint = .zero
    private var dragDistance: CGFloat = 0

    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "HoverTriggerMonitor")

    var isMonitoring: Bool { eventMonitor != nil }

    // MARK: - Lifecycle

    func start() {
        guard eventMonitor == nil else { return }

        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .rightMouseDown, .otherMouseDown, .scrollWheel
        ]
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type
            // clickCount is only defined for mouse-down/up/drag events.
            let clickCount = type == .leftMouseUp ? event.clickCount : 0
            // Global monitor handlers are documented to run on the main thread.
            MainActor.assumeIsolated {
                self?.handle(type, clickCount: clickCount)
            }
        }
        logger.info("Hover trigger monitoring started")
    }

    func stop() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
        disarm()
        logger.info("Hover trigger monitoring stopped")
    }

    /// Drops any pending trigger — called when an activation starts through
    /// another path (hotkey, menu) so the same selection isn't looked up twice.
    func cancelPendingTrigger() {
        disarm()
    }

    // MARK: - Gesture Tracking

    private func handle(_ type: NSEvent.EventType, clickCount: Int) {
        switch type {
        case .leftMouseDown:
            disarm()
            mouseDownLocation = NSEvent.mouseLocation
            dragDistance = 0
        case .leftMouseDragged:
            dragDistance = max(dragDistance, distance(from: mouseDownLocation, to: NSEvent.mouseLocation))
        case .leftMouseUp:
            // Drag-select or double/triple-click select arms; a plain click
            // has already disarmed on the way down.
            if clickCount >= 2 || dragDistance >= AppConstants.hoverSelectionDragThreshold {
                arm()
            }
        case .rightMouseDown, .otherMouseDown, .scrollWheel:
            disarm()
        default:
            break
        }
    }

    /// Watches the pointer for the arm window and fires the first time it
    /// rests (stays inside the tolerance radius) for the dwell duration.
    /// Polling instead of global mouseMoved events — those are delivered only
    /// while some app has requested mouse-moved tracking, so they can go quiet.
    private func arm() {
        dwellTask?.cancel()
        dwellTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(AppConstants.hoverArmWindowSeconds)
            var anchor = NSEvent.mouseLocation
            var restingSince = clock.now

            while !Task.isCancelled, clock.now < deadline {
                try? await Task.sleep(nanoseconds: AppConstants.hoverPollIntervalNanoseconds)
                guard !Task.isCancelled, let self else { return }

                let location = NSEvent.mouseLocation
                if self.distance(from: anchor, to: location) > AppConstants.hoverPointerTolerance {
                    anchor = location
                    restingSince = clock.now
                } else if restingSince.duration(to: clock.now) >= .seconds(AppConstants.hoverDwellSeconds) {
                    self.disarm()
                    self.logger.info("Hover dwell completed — firing trigger")
                    self.onHover?()
                    return
                }
            }
        }
    }

    private func disarm() {
        dwellTask?.cancel()
        dwellTask = nil
    }

    private func distance(from a: NSPoint, to b: NSPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}
