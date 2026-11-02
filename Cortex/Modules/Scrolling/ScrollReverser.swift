import AppKit
import CortexCore
import Synchronization

/// Reverses the scroll direction of the trackpad or the mouse, per axis, and
/// sets how far one notch of a scroll wheel scrolls.
///
/// macOS has one scroll direction ("natural scrolling") for all devices. To
/// let the mouse and the trackpad scroll differently, an event tap flips the
/// sign of scroll events from the chosen devices. The tap exists only while
/// the setting is on and has something to change.
///
/// Every app's scrolling waits for the tap, many times a second, so it runs
/// on its own thread: a busy main thread never makes scrolling lag. The
/// callback only reads the rules under a lock and negates a few numbers.
@MainActor
@Observable
final class ScrollReverser {
    enum Source: Equatable, Sendable {
        case trackpad
        /// A wheel mouse. A Magic Mouse sends trackpad-like events and counts
        /// as a trackpad.
        case mouse
    }

    struct Rules: Equatable, Sendable {
        var vertical = false
        var horizontal = false
        var trackpad = false
        var mouse = false
        /// Lines one slow wheel notch scrolls, or 0 to leave it to macOS.
        var wheelStep = 0

        /// False when the rules would change no event.
        var isEffective: Bool { (vertical || horizontal) && (trackpad || mouse) || wheelStep > 0 }

        func reverses(_ source: Source) -> Bool {
            switch source {
            case .trackpad: trackpad
            case .mouse: mouse
            }
        }
    }

    let settings: ScrollingSettings
    private(set) var isRunning = false

    @ObservationIgnored private var tap: ScrollTap?
    @ObservationIgnored private let log = Log.logger("scrolling")

    init(settings: ScrollingSettings) {
        self.settings = settings
    }

    /// Creates the event tap, or updates the rules of the running one. Fails
    /// without Accessibility permission.
    @discardableResult
    func start(rules: Rules) -> Bool {
        if let tap {
            tap.rules.withLock { $0 = rules }
            return true
        }
        guard let tap = ScrollTap(rules: rules) else {
            log.notice("Cannot create the scroll event tap (Accessibility permission missing?)")
            return false
        }
        self.tap = tap
        isRunning = true
        log.info("Scroll reversal on")
        return true
    }

    func stop() {
        guard let tap else { return }
        tap.invalidate()
        self.tap = nil
        isRunning = false
        log.info("Scroll reversal off")
    }

    // MARK: - Events

    /// Trackpad scrolling always comes with a scroll phase (fingers down) or
    /// a momentum phase (after they lift); a wheel mouse sets neither.
    nonisolated static func source(of event: CGEvent) -> Source {
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        return phase != 0 || momentum != 0 ? .trackpad : .mouse
    }

    /// Negates the event's deltas on the axes the rules reverse, if they
    /// reverse its source, and sets the step of a slow wheel notch.
    nonisolated static func apply(_ rules: Rules, to event: CGEvent) {
        let reverse = rules.reverses(source(of: event))
        // Trackpads, the Magic Mouse and smooth-scrolling mice send continuous
        // events; only a real wheel has notches.
        let wheelStep = event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 ? rules.wheelStep : 0
        adjust(event, reverse: reverse && rules.vertical, wheelStep: wheelStep,
               lines: .scrollWheelEventDeltaAxis1, fixed: .scrollWheelEventFixedPtDeltaAxis1,
               points: .scrollWheelEventPointDeltaAxis1)
        // Shift + wheel arrives here already turned into horizontal scrolling.
        adjust(event, reverse: reverse && rules.horizontal, wheelStep: wheelStep,
               lines: .scrollWheelEventDeltaAxis2, fixed: .scrollWheelEventFixedPtDeltaAxis2,
               points: .scrollWheelEventPointDeltaAxis2)
    }

    /// An axis has three deltas (lines, fixed-point lines, pixels) and apps
    /// read different ones. Setting the lines makes macOS recompute the other
    /// two (fixed = lines, pixels = 8 × lines), so all are read first.
    private nonisolated static func adjust(
        _ event: CGEvent, reverse: Bool, wheelStep: Int,
        lines: CGEventField, fixed: CGEventField, points: CGEventField
    ) {
        let lineDelta = event.getIntegerValueField(lines)
        let sign: Int64 = reverse ? -1 : 1
        // A single slow notch. Faster turns arrive as several lines, already
        // accelerated by macOS, and keep their size.
        if wheelStep > 0 && abs(lineDelta) == 1 {
            event.setIntegerValueField(lines, value: lineDelta * Int64(wheelStep) * sign)
        } else if reverse {
            let fixedDelta = event.getDoubleValueField(fixed)
            let pointDelta = event.getIntegerValueField(points)
            event.setIntegerValueField(lines, value: -lineDelta)
            event.setDoubleValueField(fixed, value: -fixedDelta)
            event.setIntegerValueField(points, value: -pointDelta)
        }
    }
}

/// The event tap and the thread whose run loop it runs on. Shared with that
/// thread: the port and run loop are set before the tap sees any event, the
/// rules sit behind a lock.
private final class ScrollTap: @unchecked Sendable {
    let rules: Mutex<ScrollReverser.Rules>
    fileprivate private(set) var port: CFMachPort?
    private var runLoop: CFRunLoop?

    init?(rules: ScrollReverser.Rules) {
        self.rules = Mutex(rules)
        // A default (not listen-only) tap, to change events: covered by the
        // Accessibility permission. It never holds back or drops an event.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: 1 << CGEventType.scrollWheel.rawValue, callback: scrollTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return nil }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)

        // The thread keeps the tap alive until its run loop stops.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let runLoop = CFRunLoopGetCurrent()
            self.runLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Cortex scroll tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func invalidate() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }
}

/// The event tap's C callback, on the tap's own thread.
private func scrollTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<ScrollTap>.fromOpaque(userInfo).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        // Without the permission (revoked while running), a re-enabled tap
        // would hold up all scrolling until the main thread tears it down.
        if let port = tap.port, AXIsProcessTrusted() { CGEvent.tapEnable(tap: port, enable: true) }
    case .scrollWheel:
        ScrollReverser.apply(tap.rules.withLock { $0 }, to: event)
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
