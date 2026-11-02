import AppKit
import Carbon.HIToolbox
import CortexCore
import Synchronization

/// Expands snippet keywords typed in any app.
///
/// An event tap sees key presses and keeps the last few characters in a
/// `KeywordBuffer`, in memory only; nothing typed is logged or stored. The
/// buffer is cleared on app switch, mouse clicks, cursor keys and any ⌘ or ⌃
/// shortcut, since the cursor may have moved. The tap exists only while
/// keyword expansion is switched on, and never changes or holds back events.
///
/// Every key press and click in every app waits for the tap, so it runs on
/// its own thread, like `ScrollReverser`'s: a busy main thread never makes
/// typing lag. The callback only updates the buffer under a lock and hops to
/// the main actor when a keyword matches.
///
/// macOS does not deliver key events to taps while secure input is on
/// (password fields, the lock screen), so keywords never expand there.
@MainActor
@Observable
final class KeywordExpander {
    enum KeyAction: Equatable {
        case type(String)
        case deleteBackward
        case reset
        case ignore
    }

    /// What the tap thread reads and writes, behind the tap's lock.
    struct State: Sendable {
        var keywords: [String: Int64] = [:]
        var buffer = KeywordBuffer()
        /// One of Cortex's windows (palette, editor) is key: typing there
        /// never expands. Kept current from the main thread.
        var ownWindowIsKey = false
    }

    private(set) var isRunning = false
    /// A keyword was typed: snippet ID and the keyword.
    @ObservationIgnored var onMatch: ((Int64, String) -> Void)?

    @ObservationIgnored private var keywords: [String: Int64] = [:]
    @ObservationIgnored private var tap: KeywordTap?
    @ObservationIgnored private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private let log = Log.logger("expansion")

    func setKeywords(_ keywords: [String: Int64]) {
        self.keywords = keywords
        tap?.state.withLock { state in
            state.keywords = keywords
            state.buffer.setKeywords(keywords.keys)
        }
    }

    /// Creates the event tap. Fails without Accessibility permission.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        var state = State(keywords: keywords, ownWindowIsKey: NSApp.keyWindow != nil)
        state.buffer.setKeywords(keywords.keys)
        let matched: @Sendable (Int64, String) -> Void = { [weak self] id, keyword in
            Task { @MainActor in self?.onMatch?(id, keyword) }
        }
        guard let tap = KeywordTap(state: state, matched: matched) else {
            log.notice("Cannot create the keyword event tap (Accessibility permission missing?)")
            return false
        }
        self.tap = tap
        observeResets()
        isRunning = true
        log.info("Keyword expansion on")
        return true
    }

    func stop() {
        guard let tap else { return }
        tap.invalidate()
        self.tap = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        isRunning = false
        log.info("Keyword expansion off")
    }

    private func observeResets() {
        let reset: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.tap?.state.withLock { $0.buffer.reset() } }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main, using: reset)))
        }
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: reset)))

        // The tap thread can't ask AppKit for the key window.
        let center = NotificationCenter.default
        for (name, isKey) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tap?.state.withLock { state in
                        state.ownWindowIsKey = isKey
                        state.buffer.reset()
                    }
                }
            }))
        }
    }

    // MARK: - Events

    /// What the tap callback passes on: everything needed, nothing more.
    struct Input: Sendable {
        var type: CGEventType
        var keyCode: Int
        var flags: CGEventFlags
        var characters: String
        var isOwn: Bool

        init(type: CGEventType, keyCode: Int, flags: CGEventFlags = [], characters: String = "", isOwn: Bool = false) {
            self.type = type
            self.keyCode = keyCode
            self.flags = flags
            self.characters = characters
            self.isOwn = isOwn
        }

        init(type: CGEventType, event: CGEvent) {
            self.type = type
            keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            flags = event.flags
            isOwn = event.getIntegerValueField(.eventSourceUserData) == Paster.eventTag
            if type == .keyDown {
                var length = 0
                var units = [UniChar](repeating: 0, count: 8)
                event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
                characters = String(utf16CodeUnits: units, count: min(length, units.count))
            } else {
                characters = ""
            }
        }
    }

    /// One event on the tap's thread: updates the buffer and returns the
    /// keyword it completed, if any.
    nonisolated static func process(_ input: Input, in state: inout State) -> (id: Int64, keyword: String)? {
        switch input.type {
        case .keyDown:
            guard !input.isOwn else { return nil }
            guard !state.ownWindowIsKey else {
                state.buffer.reset()
                return nil
            }
            switch action(keyCode: input.keyCode, flags: input.flags, characters: input.characters) {
            case .type(let characters):
                state.buffer.type(characters)
                if let keyword = state.buffer.match(in: state.keywords.keys), let id = state.keywords[keyword] {
                    state.buffer.reset()
                    return (id, keyword)
                }
            case .deleteBackward:
                state.buffer.deleteBackward()
            case .reset:
                state.buffer.reset()
            case .ignore:
                break
            }
            return nil
        default:
            // A click may have moved the cursor; a disabled tap missed keys.
            state.buffer.reset()
            return nil
        }
    }

    /// How a key press changes the buffer.
    nonisolated static func action(keyCode: Int, flags: CGEventFlags, characters: String) -> KeyAction {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return .reset }
        switch keyCode {
        case kVK_Delete:
            // ⌥⌫ deletes a word: what is left before the cursor is unknown.
            return flags.contains(.maskAlternate) ? .reset : .deleteBackward
        case kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Escape:
            return .reset
        default:
            break
        }
        // A dead key (´ before e): the composed character comes with the next key.
        guard !characters.isEmpty else { return .ignore }
        // Function keys produce private-use characters, other keys control characters.
        let isText = characters.unicodeScalars.allSatisfy { scalar in
            !(0xF700...0xF8FF).contains(scalar.value)
                && (scalar.properties.generalCategory != .control || scalar == "\r" || scalar == "\t")
        }
        return isText ? .type(characters) : .reset
    }
}

/// The event tap and the thread whose run loop it runs on. Shared with that
/// thread: the port and run loop are set before the tap sees any event, the
/// state sits behind a lock.
private final class KeywordTap: @unchecked Sendable {
    let state: Mutex<KeywordExpander.State>
    let matched: @Sendable (Int64, String) -> Void
    fileprivate private(set) var port: CFMachPort?
    private var runLoop: CFRunLoop?

    init?(state: KeywordExpander.State, matched: @escaping @Sendable (Int64, String) -> Void) {
        self.state = Mutex(state)
        self.matched = matched
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        // A default (not listen-only) tap: it is covered by the Accessibility
        // permission Cortex already has, where a listen-only tap would need
        // Input Monitoring as well. The callback passes every event through.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: keywordTapCallback,
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
        thread.name = "Cortex keyword tap"
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
private func keywordTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeywordTap>.fromOpaque(userInfo).takeUnretainedValue()
    // Without the permission (revoked while running), a re-enabled tap would
    // hold up all input until the main thread tears it down.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let port = tap.port {
        if AXIsProcessTrusted() { CGEvent.tapEnable(tap: port, enable: true) }
    }
    let input = KeywordExpander.Input(type: type, event: event)
    if let match = tap.state.withLock({ KeywordExpander.process(input, in: &$0) }) {
        tap.matched(match.id, match.keyword)
    }
    return Unmanaged.passUnretained(event)
}
